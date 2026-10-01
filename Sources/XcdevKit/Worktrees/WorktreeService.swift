import Foundation

public struct WorktreeContext: Sendable {
    public let location: ProjectLocation
    public let config: XcdevConfig
    public var state: WorktreeState

    public init(location: ProjectLocation, config: XcdevConfig, state: WorktreeState) {
        self.location = location
        self.config = config
        self.state = state
    }

    public var paths: WorktreePaths { WorktreePaths(root: location.worktreeRoot) }
}

public struct WorktreeService: Sendable {
    public let runner: any ProcessRunning
    public let globalPaths: GlobalPaths

    public init(runner: any ProcessRunning, globalPaths: GlobalPaths) {
        self.runner = runner
        self.globalPaths = globalPaths
    }

    var registry: Registry { Registry(paths: globalPaths) }

    /// Opens the worktree containing `directory`, or the project's worktree named `worktreeName`.
    /// First use of a checkout (main, or one made with plain git) initializes its state.
    public func open(from directory: String, worktreeName: String? = nil) async throws -> WorktreeContext {
        var location = try await WorktreeLocator(runner: runner).locate(from: directory)
        if let worktreeName {
            let root = worktreeName == "main"
                ? location.projectRoot
                : try entry(named: worktreeName, projectRoot: location.projectRoot).path
            guard FileManager.default.fileExists(atPath: root) else {
                throw XcdError(.worktreeNotFound, "worktree '\(worktreeName)' was deleted outside xcd",
                               next: "run `xcd wt remove \(worktreeName)` to clean it up")
            }
            location = ProjectLocation(projectRoot: location.projectRoot, worktreeRoot: root)
        }
        let config = try ConfigLoader.load(worktreeRoot: location.worktreeRoot, projectRoot: location.projectRoot)
        let paths = WorktreePaths(root: location.worktreeRoot)
        if let state = try WorktreeStateStore.load(paths) {
            return WorktreeContext(location: location, config: config, state: state)
        }
        let state = WorktreeState(
            id: UUID().uuidString,
            name: location.isMain ? "main" : URL(fileURLWithPath: location.worktreeRoot).lastPathComponent,
            project: location.projectName, projectRoot: location.projectRoot, path: location.worktreeRoot,
            branch: await currentBranch(at: location.worktreeRoot), xcode: nil, devices: [:],
            status: .ready, createdAt: Date())
        try WorktreeStateStore.save(state, paths)
        try await registry.upsert(RegistryEntry(state))
        return WorktreeContext(location: location, config: config, state: state)
    }

    /// Registered worktrees for one project, or for all projects when `projectRoot` is nil.
    public func list(projectRoot: String?) throws -> [RegistryEntry] {
        try registry.entries()
            .filter { projectRoot == nil || $0.projectRoot == projectRoot }
            .sorted { ($0.project, $0.name) < ($1.project, $1.name) }
    }

    /// `list` plus each worktree's branch, clones, and their boot state. Boot state comes from one
    /// `simctl list` call (skipped when no worktree has clones); if it fails, states are "unknown".
    public func listDetails(projectRoot: String?) async throws -> [WorktreeListItem] {
        let fm = FileManager.default
        let loaded = try list(projectRoot: projectRoot).map { entry -> (RegistryEntry, WorktreeState?, Bool) in
            let exists = fm.fileExists(atPath: entry.path)
            let state = exists ? (try? WorktreeStateStore.load(WorktreePaths(root: entry.path))) ?? nil : nil
            return (entry, state, exists)
        }
        var catalog: SimCatalog?
        if loaded.contains(where: { !($0.1?.devices.isEmpty ?? true) }) {
            catalog = try? await SimctlClient(runner: runner, developerDir: nil).catalog()
        }
        return loaded.map { entry, state, exists in
            let devices = (state?.devices ?? [:]).sorted { $0.key < $1.key }.map { name, device in
                let simState = catalog.map { $0.device(udid: device.udid)?.state ?? "gone" } ?? "unknown"
                return WorktreeListItem.Device(name: name, udid: device.udid, state: simState)
            }
            let status: WorktreeListItem.Status = !exists ? .missing : entry.status == .ready ? .ready : .incomplete
            return WorktreeListItem(entry: entry, status: status, branch: state?.branch, devices: devices)
        }
    }

    public func worktreesDirectory(for ctx: WorktreeContext) -> String {
        let template = ctx.config.worktreesRoot.replacingOccurrences(of: "{project}", with: ctx.location.projectName)
        let absolute = template.hasPrefix("/") ? template : ctx.location.projectRoot + "/" + template
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }

    /// Creates `<worktrees root>/<name>` on branch `<name>` (reusing the branch if it exists).
    /// Never clones simulators. Idempotent, and serialized per project across processes.
    public func create(name: String, from ref: String? = nil,
                       in ctx: WorktreeContext) async throws -> (state: WorktreeState, created: Bool) {
        try Self.validate(name: name)
        return try await FileLock.withLock(at: lockPath(projectRoot: ctx.location.projectRoot)) {
            try await createLocked(name: name, from: ref, in: ctx)
        }
    }

    /// The per-project lock that serializes create and remove across processes.
    func lockPath(projectRoot: String) -> String {
        let key = String(projectRoot.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return globalPaths.locksDirectory + "/worktrees-" + key + ".lock"
    }

    private func createLocked(name: String, from ref: String?,
                              in ctx: WorktreeContext) async throws -> (state: WorktreeState, created: Bool) {
        let projectRoot = ctx.location.projectRoot
        let existing = try registry.entries().first(where: { $0.projectRoot == projectRoot && $0.name == name })
        if let existing, existing.status == .ready, FileManager.default.fileExists(atPath: existing.path) {
            if let state = try WorktreeStateStore.load(WorktreePaths(root: existing.path)) { return (state, false) }
            return (try await open(from: existing.path).state, false)
        }
        let branchExists = try await runner.run(
            .git(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: projectRoot)).succeeded
        if ref != nil, branchExists {
            throw XcdError(.usage, "branch '\(name)' already exists, so --from can't be applied",
                           next: "drop --from to reuse the branch, or pick another name")
        }
        if let existing { try await discardStale(existing, projectRoot: projectRoot) }

        let path = worktreesDirectory(for: ctx) + "/" + name
        var state = WorktreeState(id: UUID().uuidString, name: name, project: ctx.location.projectName,
                                  projectRoot: projectRoot, path: path, branch: name, xcode: nil, devices: [:],
                                  status: .incomplete, createdAt: Date())
        try await registry.upsert(RegistryEntry(state))
        var worktreeAdded = false
        var branchCreated = false
        do {
            let args = branchExists
                ? ["worktree", "add", path, name]
                : ["worktree", "add", "-b", name, path, ref ?? "HEAD"]
            var add = Invocation.git(args, in: projectRoot)
            add.timeout = .seconds(600)          // checking out a large repo can take minutes
            try await runner.runChecked(add,
                                        next: "check that the --from ref exists and the branch isn't checked out elsewhere")
            worktreeAdded = true
            branchCreated = !branchExists
            state.path = Paths.canonical(path)
            let paths = WorktreePaths(root: state.path)
            try WorktreeStateStore.save(state, paths)
            let seed = WorktreePaths(root: projectRoot).sourcePackages
            if FileManager.default.fileExists(atPath: seed) {
                // APFS clonefile copy: instant and space-free until files diverge.
                try await runner.runChecked(Invocation("/bin/cp", ["-c", "-R", seed, paths.sourcePackages]))
            }
            state.status = .ready
            try WorktreeStateStore.save(state, paths)
            try await registry.upsert(RegistryEntry(state))
            return (state, true)
        } catch {
            // Undo only what this attempt created; never touch a checkout that was already there.
            if worktreeAdded {
                _ = try? await runner.run(.git(["worktree", "remove", "--force", path], in: projectRoot))
            }
            if branchCreated {
                _ = try? await runner.run(.git(["branch", "-D", name], in: projectRoot))
            }
            _ = try? await runner.run(.git(["worktree", "prune"], in: projectRoot))
            try? await registry.remove(id: state.id)
            throw error
        }
    }

    func entry(named name: String, projectRoot: String) throws -> RegistryEntry {
        guard let entry = try registry.entries().first(where: { $0.projectRoot == projectRoot && $0.name == name }) else {
            throw XcdError(.worktreeNotFound, "no worktree named '\(name)' in this project",
                           next: "run `xcd wt list` to see this project's worktrees")
        }
        return entry
    }

    /// Clears a stale registry entry left by an interrupted creation. The checkout on disk is removed only
    /// when it is provably xcd's (matching state id) and clean; otherwise only the entry is dropped.
    func discardStale(_ entry: RegistryEntry, projectRoot: String) async throws {
        if FileManager.default.fileExists(atPath: entry.path) {
            let stored = try? WorktreeStateStore.load(WorktreePaths(root: entry.path))
            var clean = false
            if stored?.id == entry.id,
               let status = try? await runner.run(.git(["status", "--porcelain"], in: entry.path)), status.succeeded {
                clean = status.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard clean else {
                try await registry.remove(id: entry.id)
                throw XcdError(.usage, "'\(entry.name)' was left half-created at \(entry.path) and has changes or isn't xcd's",
                               next: "inspect it, then remove it with `git worktree remove \(Shell.quote(entry.path))` and re-run `xcd wt create \(entry.name)`")
            }
            _ = try? await runner.run(.git(["worktree", "remove", "--force", entry.path], in: projectRoot))
        }
        _ = try? await runner.run(.git(["worktree", "prune"], in: projectRoot))
        try await registry.remove(id: entry.id)
    }

    func currentBranch(at path: String) async -> String? {
        guard let out = try? await runner.run(.git(["rev-parse", "--abbrev-ref", "HEAD"], in: path)),
              out.succeeded else { return nil }
        let branch = out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch == "HEAD" ? nil : branch
    }

    static func validate(name: String) throws {
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$"#
        let valid = name.range(of: pattern, options: .regularExpression) != nil
            && name != "main" && !name.hasSuffix(".lock") && !name.contains("..")
        guard valid else {
            throw XcdError(.usage, "'\(name)' is not a valid worktree name",
                           next: "use letters, digits, '.', '_' or '-' (not 'main'), e.g. `xcd wt create login-flow`")
        }
    }
}

public struct WorktreeRemoval: Codable, Sendable, Equatable {
    public let name: String
    public let project: String
    public let path: String
    public let branch: String
    public let removedDevices: [String]
    /// True when the checkout or its state was already gone, so clones (if any) could not be found.
    public let stateMissing: Bool
}

extension WorktreeService {
    /// Deletes the worktree's clones, the git worktree, and its registry entry. Keeps the branch.
    /// Serialized with `create` per project across processes.
    public func remove(name: String, force: Bool = false, in ctx: WorktreeContext) async throws -> WorktreeRemoval {
        guard name != "main" else { throw XcdError(.usage, "the main worktree cannot be removed") }
        return try await FileLock.withLock(at: lockPath(projectRoot: ctx.location.projectRoot)) {
            try await removeLocked(name: name, force: force, in: ctx)
        }
    }

    private func removeLocked(name: String, force: Bool, in ctx: WorktreeContext) async throws -> WorktreeRemoval {
        let projectRoot = ctx.location.projectRoot
        let entry = try entry(named: name, projectRoot: projectRoot)
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: entry.path)

        if exists && !force {
            let status = try await runner.runChecked(.git(["status", "--porcelain"], in: entry.path))
            let changes = status.stdoutString.split(separator: "\n").map(String.init)
            if !changes.isEmpty {
                throw XcdError(.worktreeDirty, "worktree '\(name)' has uncommitted changes",
                               next: "commit or stash them, or re-run `xcd wt remove \(name) --force`",
                               details: Array(changes.prefix(20)))
            }
        }

        let state = exists ? try WorktreeStateStore.load(WorktreePaths(root: entry.path)) : nil
        var removedDevices: [String] = []
        if let state, !state.devices.isEmpty {
            let simctl = SimctlClient(runner: runner, developerDir: state.xcode?.developerDir)
            for (deviceName, device) in state.devices.sorted(by: { $0.key < $1.key }) {
                _ = try? await simctl.shutdown(udid: device.udid)
                try await simctl.delete(udid: device.udid)
                removedDevices.append(deviceName)
            }
        }

        if exists {
            // Cleanliness was checked above (or the caller forced), so --force only lets git
            // delete ignored build state such as .xcdev/.
            try await runner.runChecked(.git(["worktree", "remove", "--force", entry.path], in: projectRoot),
                                        next: "close anything using the worktree, then re-run `xcd wt remove \(name)`")
        }
        _ = try? await runner.run(.git(["worktree", "prune"], in: projectRoot))
        if fm.fileExists(atPath: entry.path) { try? fm.removeItem(atPath: entry.path) }
        try await registry.remove(id: entry.id)
        return WorktreeRemoval(name: name, project: ctx.location.projectName, path: entry.path, branch: state?.branch ?? name,
                               removedDevices: removedDevices, stateMissing: state == nil)
    }
}

/// One row of `xcd wt list`.
public struct WorktreeListItem: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case ready, incomplete, missing }

    public struct Device: Codable, Sendable, Equatable {
        public let name: String
        public let udid: String
        /// simctl's state ("Booted", "Shutdown", …), "gone" if the clone no longer exists, or "unknown".
        public let state: String

        public init(name: String, udid: String, state: String) {
            self.name = name
            self.udid = udid
            self.state = state
        }
    }

    public let project: String
    public let name: String
    public let path: String
    public let status: Status
    public let branch: String?
    /// Sorted by name.
    public let devices: [Device]

    public init(entry: RegistryEntry, status: Status, branch: String?, devices: [Device]) {
        project = entry.project
        name = entry.name
        path = entry.path
        self.status = status
        self.branch = branch
        self.devices = devices
    }
}
