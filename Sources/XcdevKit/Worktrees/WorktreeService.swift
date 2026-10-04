import Foundation

public struct WorktreeContext: Sendable {
    public let location: ProjectLocation
    public let config: XcdevConfig
    public var state: WorktreeState
    /// `--xcode` for this command only. Never written to worktree.json.
    public var xcodeOverride: XcodeInstall?

    public init(location: ProjectLocation, config: XcdevConfig, state: WorktreeState, xcodeOverride: XcodeInstall? = nil) {
        self.location = location
        self.config = config
        self.state = state
        self.xcodeOverride = xcodeOverride
    }

    public var paths: WorktreePaths { WorktreePaths(root: location.worktreeRoot) }
    /// The Xcode this command uses: the override, else the worktree's pinned one.
    public var xcode: XcodeInstall? { xcodeOverride ?? state.xcode }
}

public struct WorktreeService: Sendable {
    public let runner: any ProcessRunning
    public let globalPaths: GlobalPaths
    /// Runs `post-worktree-create` and `pre-worktree-remove`. Nil runs no hooks.
    public let hooks: HookRunner?
    /// Stops a removed worktree's screen recordings.
    public let detached: any DetachedProcessLaunching

    public init(runner: any ProcessRunning, globalPaths: GlobalPaths, hooks: HookRunner? = nil,
                detached: any DetachedProcessLaunching = SystemDetachedProcesses()) {
        self.runner = runner
        self.globalPaths = globalPaths
        self.hooks = hooks
        self.detached = detached
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

    /// `list` plus each worktree's branch, clones, their boot state, and the size of its `.xcdev/` folder.
    /// Boot state comes from one `simctl list` call (skipped when no worktree has clones); if it fails, states
    /// are "unknown". Sizes come from one `du` call; if it fails, sizes are left out.
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
        let sizes = await DiskUsage(runner: runner).bytes(of: loaded.filter(\.2).map { WorktreePaths(root: $0.0.path).stateDirectory })
        return loaded.map { entry, state, exists in
            let devices = (state?.devices ?? [:]).sorted { $0.key < $1.key }.map { name, device in
                let simState = catalog.map { $0.device(udid: device.udid)?.state ?? "gone" } ?? "unknown"
                return WorktreeListItem.Device(name: name, udid: device.udid, state: simState)
            }
            let status: WorktreeListItem.Status = !exists ? .missing : entry.status == .ready ? .ready : .incomplete
            return WorktreeListItem(entry: entry, status: status, branch: state?.branch, devices: devices,
                                    diskBytes: sizes[WorktreePaths(root: entry.path).stateDirectory])
        }
    }

    public func worktreesDirectory(for ctx: WorktreeContext) -> String {
        let template = ctx.config.worktreesRoot.replacingOccurrences(of: "{project}", with: ctx.location.projectName)
        let absolute = template.hasPrefix("/") ? template : ctx.location.projectRoot + "/" + template
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }

    /// Creates `<worktrees root>/<name>` on branch `<name>` (reusing the branch if it exists), then runs the new
    /// checkout's `post-worktree-create` hook. Never clones simulators. Idempotent, and serialized per project
    /// across processes.
    ///
    /// The hook can take 30 minutes, so it runs outside the per-project lock, which is held only to add the
    /// checkout and again to mark it ready (or roll it back). The worktree's own lock is held throughout, so no
    /// other create or remove of this name can see it half-made, while other worktrees are never blocked.
    public func create(name: String, from ref: String? = nil,
                       in ctx: WorktreeContext) async throws -> (state: WorktreeState, created: Bool) {
        try Self.validate(name: name)
        let projectRoot = ctx.location.projectRoot
        return try await FileLock.withLock(at: lockPath(projectRoot: projectRoot, worktree: name)) {
            let checkout = try await FileLock.withLock(at: lockPath(projectRoot: projectRoot)) {
                try await addCheckout(name: name, from: ref, in: ctx)
            }
            guard checkout.created else { return (checkout.state, false) }
            let state = checkout.state
            do {
                try await runPostCreateHook(state, in: ctx)
                return (try await FileLock.withLock(at: lockPath(projectRoot: projectRoot)) {
                    // Reload: the hook may have run xcd in the new worktree, pinning an Xcode or cloning a simulator.
                    let paths = WorktreePaths(root: state.path)
                    var ready = try WorktreeStateStore.load(paths) ?? state
                    ready.status = .ready
                    try WorktreeStateStore.save(ready, paths)
                    try await registry.upsert(RegistryEntry(ready))
                    return ready
                }, true)
            } catch {
                _ = try? await FileLock.withLock(at: lockPath(projectRoot: projectRoot)) {
                    await rollBack(state, worktreeAdded: true, branchCreated: checkout.branchCreated)
                }
                guard var error = error as? XcdError else { throw error }
                switch error.code {
                case .hookFailed:
                    error.next = "fix hooks.post-worktree-create (its output is in the log), then re-run `xcd wt create \(name)`"
                case .configInvalid:
                    error.next = "fix .xcdev.yml on branch '\(name)', then re-run `xcd wt create \(name)`"
                default:
                    break
                }
                error.details.append(checkout.branchCreated
                    ? "the worktree was not created: its checkout and branch were rolled back"
                    : "the worktree was not created: its checkout was rolled back, and branch '\(name)', which already existed, was kept")
                throw error
            }
        }
    }

    /// The per-project lock that serializes create and remove across processes.
    func lockPath(projectRoot: String) -> String {
        let key = String(projectRoot.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return globalPaths.locksDirectory + "/worktrees-" + key + ".lock"
    }

    /// One worktree's lock, held (before the project lock, never after it) for a whole create or remove,
    /// including its hook. `worktree` is a validated name, so it is safe in a file name.
    func lockPath(projectRoot: String, worktree: String) -> String {
        String(lockPath(projectRoot: projectRoot).dropLast(".lock".count)) + "--" + worktree + ".lock"
    }

    /// The checkout's own config, which its hooks (and their scripts) come from, or nil when it has no
    /// .xcdev.yml. Never the caller's config: the hook's script may not exist on this checkout's branch.
    func hookConfig(worktree: String, projectRoot: String) throws -> XcdevConfig? {
        do {
            return try ConfigLoader.load(worktreeRoot: worktree, projectRoot: projectRoot)
        } catch let error as XcdError where error.code == .configMissing {
            return nil
        }
    }

    /// Runs the new checkout's `post-worktree-create`, logging to the calling worktree so the log survives a rollback.
    private func runPostCreateHook(_ state: WorktreeState, in ctx: WorktreeContext) async throws {
        guard let hooks, let config = try hookConfig(worktree: state.path, projectRoot: ctx.location.projectRoot) else {
            return
        }
        try await hooks.run(.postWorktreeCreate, config: config, context: .worktree(state, config: config, output: hooks.output),
                            logs: ctx.paths)
    }

    /// The result of the locked part of `create`: an `incomplete` new checkout, or an existing ready one.
    private struct Checkout: Sendable {
        var state: WorktreeState
        var created: Bool
        var branchCreated: Bool
    }

    private func addCheckout(name: String, from ref: String?, in ctx: WorktreeContext) async throws -> Checkout {
        let projectRoot = ctx.location.projectRoot
        let existing = try registry.entries().first(where: { $0.projectRoot == projectRoot && $0.name == name })
        if let existing, existing.status == .ready, FileManager.default.fileExists(atPath: existing.path) {
            let stored = try WorktreeStateStore.load(WorktreePaths(root: existing.path))
            let state = if let stored { stored } else { try await open(from: existing.path).state }
            return Checkout(state: state, created: false, branchCreated: false)
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
            return Checkout(state: state, created: true, branchCreated: branchCreated)
        } catch {
            await rollBack(state, worktreeAdded: worktreeAdded, branchCreated: branchCreated)
            throw error
        }
    }

    /// Undoes a creation attempt: only what it created, never a checkout or branch that was already there.
    /// Simulators cloned into the new checkout (by xcd run from its hook) are deleted with it.
    /// The caller holds the project lock.
    private func rollBack(_ state: WorktreeState, worktreeAdded: Bool, branchCreated: Bool) async {
        let projectRoot = state.projectRoot
        if worktreeAdded {
            if let stored = try? WorktreeStateStore.load(WorktreePaths(root: state.path)) {
                _ = try? await deleteClones(of: stored)
            }
            _ = try? await runner.run(.git(["worktree", "remove", "--force", state.path], in: projectRoot))
        }
        if branchCreated {
            _ = try? await runner.run(.git(["branch", "-D", state.name], in: projectRoot))
        }
        _ = try? await runner.run(.git(["worktree", "prune"], in: projectRoot))
        try? await registry.remove(id: state.id)
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
    /// One line per screen recording stopped before the clones were deleted.
    public var stoppedRecordings: [String] = []
    /// Problems that `--force` removed the worktree despite, such as a failing `pre-worktree-remove` hook.
    public var warnings: [String] = []
}

extension WorktreeService {
    /// Runs the worktree's `pre-worktree-remove` hook, then deletes its clones, the git worktree, and its registry
    /// entry. Keeps the branch. Serialized with `create` per project across processes.
    ///
    /// A dirty worktree is refused before the hook runs, so teardown never runs for a removal that is then refused,
    /// and again after it if tracked files changed while it ran.
    /// The hook runs before the per-project lock is taken (under the worktree's own lock, as in `create`).
    /// `force` skips the dirty check and turns a failing hook into a warning in the result.
    public func remove(name: String, force: Bool = false, in ctx: WorktreeContext) async throws -> WorktreeRemoval {
        guard name != "main" else { throw XcdError(.usage, "the main worktree cannot be removed") }
        let projectRoot = ctx.location.projectRoot
        _ = try entry(named: name, projectRoot: projectRoot)   // only registered (so valid) names reach a lock path
        return try await FileLock.withLock(at: lockPath(projectRoot: projectRoot, worktree: name)) {
            let entry = try entry(named: name, projectRoot: projectRoot)
            var warnings: [String] = []
            if FileManager.default.fileExists(atPath: entry.path) {
                if !force { try await checkClean(entry) }
                warnings = try await runPreRemoveHook(entry, force: force, in: ctx)
                // The hook may have run for minutes: tracked edits made meanwhile would be lost to
                // `git worktree remove --force`. Files the hook itself left behind are untracked and don't count.
                if !force { try await checkClean(entry, untracked: false) }
            }
            return try await FileLock.withLock(at: lockPath(projectRoot: projectRoot)) {
                try await removeLocked(name: name, warnings: warnings, in: ctx)
            }
        }
    }

    /// Throws `worktree_dirty` when the worktree has changes; `untracked: false` counts tracked files only.
    private func checkClean(_ entry: RegistryEntry, untracked: Bool = true) async throws {
        let args = ["status", "--porcelain"] + (untracked ? [] : ["--untracked-files=no"])
        let status = try await runner.runChecked(.git(args, in: entry.path))
        let changes = status.stdoutString.split(separator: "\n").map(String.init)
        if !changes.isEmpty {
            throw XcdError(.worktreeDirty, "worktree '\(entry.name)' has uncommitted changes",
                           next: "commit or stash them, or re-run `xcd wt remove \(entry.name) --force`",
                           details: Array(changes.prefix(20)))
        }
    }

    /// Runs the doomed worktree's own `pre-worktree-remove` from inside it. A failure (or an invalid config) keeps
    /// the worktree, unless `force`, which returns it as a warning instead.
    private func runPreRemoveHook(_ entry: RegistryEntry, force: Bool, in ctx: WorktreeContext) async throws -> [String] {
        guard let hooks, let state = try? WorktreeStateStore.load(WorktreePaths(root: entry.path)) else { return [] }
        do {
            guard let config = try hookConfig(worktree: entry.path, projectRoot: ctx.location.projectRoot) else { return [] }
            try await hooks.run(.preWorktreeRemove, config: config, context: .worktree(state, config: config, output: hooks.output),
                                logs: ctx.paths)
            return []
        } catch var error as XcdError {
            let log = error.details.first { $0.hasPrefix("log: ") }.map { " (" + $0 + ")" } ?? ""
            if force { return [error.message + "; removed anyway because of --force" + log] }
            if error.code == .hookFailed {
                error.next = "fix hooks.pre-worktree-remove (its output is in the log), then re-run `xcd wt remove \(entry.name)`;"
                    + " `--force` removes it without the hook succeeding, discarding any uncommitted changes"
            }
            error.details.append("the worktree was kept")
            throw error
        }
    }

    /// Shuts down and deletes the simulators cloned for `state`. Returns their device names, sorted.
    func deleteClones(of state: WorktreeState) async throws -> [String] {
        guard !state.devices.isEmpty else { return [] }
        let simctl = SimctlClient(runner: runner, developerDir: state.xcode?.developerDir)
        var removed: [String] = []
        for (deviceName, device) in state.devices.sorted(by: { $0.key < $1.key }) {
            _ = try? await simctl.shutdown(udid: device.udid)
            try await simctl.delete(udid: device.udid)
            removed.append(deviceName)
        }
        return removed
    }

    private func removeLocked(name: String, warnings: [String], in ctx: WorktreeContext) async throws -> WorktreeRemoval {
        let projectRoot = ctx.location.projectRoot
        let entry = try entry(named: name, projectRoot: projectRoot)
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: entry.path)

        let state = exists ? try WorktreeStateStore.load(WorktreePaths(root: entry.path)) : nil
        let stopped = exists ? await Recordings.stopAll(in: WorktreePaths(root: entry.path), detached: detached, now: Date()) : []
        let removedDevices = if let state { try await deleteClones(of: state) } else { [String]() }

        if exists {
            // Cleanliness was checked around the hook (or the caller forced), so --force only lets git
            // delete ignored build state such as .xcdev/.
            try await runner.runChecked(.git(["worktree", "remove", "--force", entry.path], in: projectRoot),
                                        next: "close anything using the worktree, then re-run `xcd wt remove \(name)`")
        }
        _ = try? await runner.run(.git(["worktree", "prune"], in: projectRoot))
        if fm.fileExists(atPath: entry.path) { try? fm.removeItem(atPath: entry.path) }
        try await registry.remove(id: entry.id)
        return WorktreeRemoval(name: name, project: ctx.location.projectName, path: entry.path, branch: state?.branch ?? name,
                               removedDevices: removedDevices, stateMissing: state == nil,
                               stoppedRecordings: stopped.map(\.note), warnings: warnings)
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
    /// Size of the worktree's `.xcdev/` folder (DerivedData, logs, results), when known.
    public let diskBytes: Int64?

    public init(entry: RegistryEntry, status: Status, branch: String?, devices: [Device], diskBytes: Int64? = nil) {
        project = entry.project
        name = entry.name
        path = entry.path
        self.status = status
        self.branch = branch
        self.devices = devices
        self.diskBytes = diskBytes
    }
}
