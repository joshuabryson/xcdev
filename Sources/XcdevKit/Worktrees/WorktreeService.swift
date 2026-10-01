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
        let projectRoot = ctx.location.projectRoot
        let key = String(projectRoot.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return try await FileLock.withLock(at: globalPaths.locksDirectory + "/worktrees-" + key + ".lock") {
            try await createLocked(name: name, from: ref, in: ctx)
        }
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
            try await runner.runChecked(.git(args, in: projectRoot),
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
