import Foundation

public struct WorktreeContext: Sendable {
    public let location: ProjectLocation
    public let config: XcdevConfig
    public var state: WorktreeState
    /// `--xcode` for this command only. Never written to worktree.json.
    public var xcodeOverride: XcodeInstall?
    /// The main checkout's `.xcdev.yml` when `config` is borrowed from it, since this checkout's branch has none.
    public var borrowedConfig: String?
    /// `--idle` for this command only, in seconds (0 = off). Set by `Services.open`; never written to worktree.json.
    public var idleOverride: Int?
    /// Whether this command has checked the pinned Xcode against `xcode:` (`DeviceProvisioner.ensureXcode`).
    public var xcodePinChecked = false

    public init(location: ProjectLocation, config: XcdevConfig, state: WorktreeState, xcodeOverride: XcodeInstall? = nil,
                borrowedConfig: String? = nil) {
        self.location = location
        self.config = config
        self.state = state
        self.xcodeOverride = xcodeOverride
        self.borrowedConfig = borrowedConfig
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
    /// Where opening a checkout leaves notes for the command's result.
    public var notes = Notes()

    public init(runner: any ProcessRunning, globalPaths: GlobalPaths, hooks: HookRunner? = nil,
                detached: any DetachedProcessLaunching = SystemDetachedProcesses()) {
        self.runner = runner
        self.globalPaths = globalPaths
        self.hooks = hooks
        self.detached = detached
    }

    var registry: Registry { Registry(paths: globalPaths) }

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
        let made = try await createTracked(name: name, from: ref, in: ctx)
        return (made.state, made.created)
    }

    /// Runs a new checkout's hook outside the per-project lock, then marks it ready under it; rolls it back when either fails.
    private func finish(_ checkout: Checkout, in ctx: WorktreeContext) async throws -> CreatedWorktree {
        let projectRoot = ctx.location.projectRoot
        do {
            let hookRan = try await runPostCreateHook(checkout.state, in: ctx)
            let state = try await FileLock.withLock(at: lockPath(projectRoot: projectRoot)) { try await markReady(checkout.state) }
            return CreatedWorktree(state: state, created: true, branchCreated: checkout.branchCreated,
                                   packagesSeeded: checkout.packagesSeeded, hookRan: hookRan)
        } catch {
            _ = try? await FileLock.withLock(at: lockPath(projectRoot: projectRoot)) {
                await rollBack(checkout.state, worktreeAdded: true, branchCreated: checkout.branchCreated)
            }
            throw Self.notCreated(error, name: checkout.state.name, branchCreated: checkout.branchCreated)
        }
    }

    /// Reloads the state first: the hook may have run xcd in the new worktree, pinning an Xcode or cloning a simulator.
    private func markReady(_ state: WorktreeState) async throws -> WorktreeState {
        let paths = WorktreePaths(root: state.path)
        var ready = try WorktreeStateStore.load(paths) ?? state
        ready.status = .ready
        try WorktreeStateStore.save(ready, paths)
        try await registry.upsert(RegistryEntry(ready))
        return ready
    }

    /// A failed create's error, saying what to fix and what the rollback kept.
    static func notCreated(_ error: any Error, name: String, branchCreated: Bool) -> any Error {
        guard var error = error as? XcdError else { return error }
        switch error.code {
        case .hookFailed:
            error.next = "fix hooks.post-worktree-create (its output is in the log), then re-run `xcd wt create \(name)`"
        case .configInvalid:
            error.next = "fix .xcdev.yml on branch '\(name)', then re-run `xcd wt create \(name)`"
        default:
            break
        }
        error.details.append(branchCreated
            ? "the worktree was not created: its checkout and branch were rolled back"
            : "the worktree was not created: its checkout was rolled back, and branch '\(name)', which already existed, was kept")
        return error
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

    /// Runs the new checkout's `post-worktree-create`, logging to the calling worktree so the log survives a rollback.
    /// True when the new checkout's `post-worktree-create` ran. False when none is configured.
    private func runPostCreateHook(_ state: WorktreeState, in ctx: WorktreeContext) async throws -> Bool {
        guard let hooks, let config = try hookConfig(worktree: state.path, projectRoot: ctx.location.projectRoot) else {
            return false
        }
        let log = try await hooks.run(.postWorktreeCreate, config: config,
                                      context: .worktree(state, config: config, output: hooks.output), logs: ctx.paths)
        return log != nil
    }

    /// The result of the locked part of `create`: an `incomplete` new checkout, or an existing ready one.
    private struct Checkout: Sendable {
        var state: WorktreeState
        var created: Bool
        var branchCreated: Bool
        var packagesSeeded = false
    }

    private func addCheckout(name: String, from ref: String?, in ctx: WorktreeContext) async throws -> Checkout {
        let projectRoot = ctx.location.projectRoot
        let existing = try checkName(name, in: ctx)
        if let existing, existing.status == .ready, FileManager.default.fileExists(atPath: existing.path) {
            return Checkout(state: try await reopen(existing), created: false, branchCreated: false)
        }
        let branchExists = try await runner.run(
            .git(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: projectRoot)).succeeded
        if ref != nil, branchExists {
            throw XcdError(.usage, "branch '\(name)' already exists, so --from can't be applied",
                           next: "drop --from to reuse the branch, or pick another name")
        }
        if let existing { try await discardStale(existing, projectRoot: projectRoot) }

        let path = worktreesDirectory(for: ctx) + "/" + name
        let state = WorktreeState(id: UUID().uuidString, name: name, project: ctx.location.projectName,
                                  projectRoot: projectRoot, path: path, branch: name, xcode: nil, devices: [:],
                                  status: .incomplete, createdAt: Date())
        try await registry.upsert(RegistryEntry(state))
        return try await addWorktree(state, branchExists: branchExists, from: ref)
    }

    /// The state of a ready worktree of xcd's. One whose state was deleted is set up again, under the project's lock,
    /// which `create` holds.
    private func reopen(_ existing: RegistryEntry) async throws -> WorktreeState {
        if let stored = try WorktreeStateStore.load(WorktreePaths(root: existing.path)) { return stored }
        let location = ProjectLocation(projectRoot: existing.projectRoot, worktreeRoot: existing.path)
        return try await FirstUseSetup(service: self).registerHoldingLock(location, hookPending: false)
    }

    /// Adds the git worktree of a registered `incomplete` state, saves the state in it, and seeds its packages. Rolls
    /// back what it made when a step fails.
    private func addWorktree(_ incomplete: WorktreeState, branchExists: Bool, from ref: String?) async throws -> Checkout {
        var state = incomplete
        var worktreeAdded = false
        do {
            let args = branchExists
                ? ["worktree", "add", state.path, state.name]
                : ["worktree", "add", "-b", state.name, state.path, ref ?? "HEAD"]
            var add = Invocation.git(args, in: state.projectRoot)
            add.timeout = .seconds(600)          // checking out a large repo can take minutes
            try await runner.runChecked(add,
                                        next: "check that the --from ref exists and the branch isn't checked out elsewhere")
            worktreeAdded = true
            state.path = Paths.canonical(state.path)
            let paths = WorktreePaths(root: state.path)
            try WorktreeStateStore.save(state, paths)
            let seeded = try await seedSourcePackages(from: state.projectRoot, into: paths)
            return Checkout(state: state, created: true, branchCreated: !branchExists, packagesSeeded: seeded)
        } catch {
            await rollBack(state, worktreeAdded: worktreeAdded, branchCreated: worktreeAdded && !branchExists)
            throw error
        }
    }

    /// The project's resolved packages are copied into a new checkout, so it doesn't resolve them again.
    /// True when the copy ran.
    @discardableResult
    func seedSourcePackages(from projectRoot: String, into paths: WorktreePaths) async throws -> Bool {
        Disk.remove(paths.partialSourcePackages)
        let seed = WorktreePaths(root: projectRoot).sourcePackages
        guard FileManager.default.fileExists(atPath: seed) else { return false }
        guard !Disk.exists(paths.sourcePackages) else { return false }
        // APFS clonefile copy: instant and space-free until files diverge. Copied beside it and moved in, so an
        // interrupted copy never looks like the packages.
        try await runner.runChecked(Invocation("/bin/cp", ["-c", "-R", seed, paths.partialSourcePackages]))
        try await runner.runChecked(Invocation("/bin/mv", [paths.partialSourcePackages, paths.sourcePackages]))
        return true
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
    /// The branch kept, or for a checkout xcd keeps, its branch; nil on a detached HEAD. Left out of the JSON when nil.
    public let branch: String?
    public let removedDevices: [String]
    /// True when the checkout or its state was already gone, so clones (if any) could not be found.
    public let stateMissing: Bool
    /// One line per screen recording stopped before the clones were deleted.
    public var stoppedRecordings: [String] = []
    /// One line per UI runner stopped (or stale runner record removed) before the clones were deleted.
    public var stoppedRunners: [String] = []
    /// Problems that `--force` removed the worktree despite, such as a failing `pre-worktree-remove` hook.
    public var warnings: [String] = []
    /// True for a checkout xcd did not make: its folder and branch were left to whatever made them.
    public var keptCheckout = false
    /// True for a checkout xcd did not make whose folder was already gone.
    public var checkoutGone = false
    /// Bytes of the checkout folder, excluding `.xcdev`, when this command deleted that folder.
    /// Nil when the folder was kept, or when `du` could not measure it.
    public var checkoutBytes: Int64? = nil
    /// Bytes of `.xcdev` (DerivedData, SourcePackages, logs, results) this command deleted.
    public var stateBytes: Int64? = nil
    /// Bytes simctl reported for the clones this command deleted.
    public var cloneBytes: Int64? = nil
}

extension WorktreeService {
    /// `create`, plus whether the branch, the package copy, and the hook happened, for the create report.
    func createTracked(name: String, from ref: String? = nil, in ctx: WorktreeContext) async throws -> CreatedWorktree {
        try Self.validate(name: name)
        let projectRoot = ctx.location.projectRoot
        return try await FileLock.withLock(at: lockPath(projectRoot: projectRoot, worktree: name)) {
            let checkout = try await FileLock.withLock(at: lockPath(projectRoot: projectRoot)) {
                try await addCheckout(name: name, from: ref, in: ctx)
            }
            guard checkout.created else { return CreatedWorktree(state: checkout.state, created: false) }
            return try await finish(checkout, in: ctx)
        }
    }

    /// Runs the worktree's `pre-worktree-remove` hook, then deletes its clones, the git worktree, and its registry
    /// entry. Keeps the branch. Serialized with `create` per project across processes. A checkout xcd did not make
    /// keeps its folder too, so neither the dirty check nor the hook applies: only xcd's part of it goes.
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
            if Disk.exists(entry.path), isXcds(entry, in: ctx) {
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
        let exists = Disk.exists(entry.path)
        let state = exists ? try WorktreeStateStore.load(WorktreePaths(root: entry.path)) : nil
        let stopped = exists ? await Recordings.stopAll(in: WorktreePaths(root: entry.path), detached: detached, now: Date()) : []
        let runners = exists ? await Runners.stopAll(in: WorktreePaths(root: entry.path), detached: detached) : []
        await endWatchdogs(of: state)
        let keepsCheckout = !isXcds(entry, in: ctx)
        let freed = await freedDisk(of: entry, state: state, keepsCheckout: keepsCheckout)
        let removedDevices = if let state { try await deleteClones(of: state) } else { [String]() }
        let branch = keepsCheckout ? await keptBranch(state, at: entry.path, exists: exists) : state?.branch ?? name
        if keepsCheckout {
            Disk.remove(WorktreePaths(root: entry.path).stateDirectory)
        } else {
            try await removeCheckout(entry, exists: exists, projectRoot: projectRoot)
        }
        try await registry.remove(id: entry.id)
        return WorktreeRemoval(name: name, project: ctx.location.projectName, path: entry.path, branch: branch,
                               removedDevices: removedDevices, stateMissing: state == nil,
                               stoppedRecordings: stopped.map(\.note), stoppedRunners: runners, warnings: warnings,
                               keptCheckout: keepsCheckout, checkoutGone: keepsCheckout && !exists,
                               checkoutBytes: freed.checkoutBytes, stateBytes: freed.stateBytes, cloneBytes: freed.cloneBytes)
    }

    /// Ends the idle watchdog and lease of every clone of `state`, so none outlives its simulator.
    private func endWatchdogs(of state: WorktreeState?) async {
        let watchdogs = Watchdogs(leases: DeviceLeases(globalPaths: globalPaths), detached: detached)
        for device in state?.devices.values.sorted(by: { $0.udid < $1.udid }) ?? [] { await watchdogs.end(device.udid) }
    }

    /// Removes the git worktree of one of xcd's own worktrees, and whatever is left of its folder.
    private func removeCheckout(_ entry: RegistryEntry, exists: Bool, projectRoot: String) async throws {
        if exists {
            // Cleanliness was checked around the hook (or the caller forced), so --force only lets git
            // delete ignored build state such as .xcdev/.
            try await runner.runChecked(.git(["worktree", "remove", "--force", entry.path], in: projectRoot),
                                        next: "close anything using the worktree, then re-run `xcd wt remove \(entry.name)`")
        }
        _ = try? await runner.run(.git(["worktree", "prune"], in: projectRoot))
        if Disk.exists(entry.path) { Disk.remove(entry.path) }
    }

    /// Whether `entry`'s checkout is one `create` made: a folder directly inside this project's worktrees folder. Any
    /// other belongs to whatever made it, the user or an agent's tool, even one nested inside
    /// an xcd worktree.
    func isXcds(_ entry: RegistryEntry, in ctx: WorktreeContext) -> Bool {
        Paths.canonical((entry.path as NSString).deletingLastPathComponent) == Paths.canonical(worktreesDirectory(for: ctx))
    }

    /// The branch of a checkout xcd leaves in place: the one git reports now while its folder is there (the state's
    /// is only what it had at first use), else the state's; nil on a detached HEAD.
    private func keptBranch(_ state: WorktreeState?, at path: String, exists: Bool) async -> String? {
        if exists { return await currentBranch(at: path) }
        return state?.branch
    }
}
