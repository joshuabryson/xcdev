import Foundation

/// What xcd does the first time it sees a checkout it did not make: the main checkout, or a worktree made with plain
/// git or by an agent's tool.
struct FirstUseSetup: Sendable {
    let service: WorktreeService

    /// Under the project's lock, the lock `xcd wt create` takes: names and registers the checkout, and copies the main
    /// checkout's resolved packages into a worktree. A state another command saved meanwhile is returned as it is.
    func register(_ location: ProjectLocation) async throws -> WorktreeState {
        try await FileLock.withLock(at: service.lockPath(projectRoot: location.projectRoot)) {
            try await registerHoldingLock(location, hookPending: !location.isMain)
        }
    }

    /// `register` for a caller that already holds the project's lock: `xcd wt create`, meeting a worktree of its own
    /// whose state was deleted, and whose hook ran when it was made.
    func registerHoldingLock(_ location: ProjectLocation, hookPending: Bool) async throws -> WorktreeState {
        let paths = WorktreePaths(root: location.worktreeRoot)
        if let saved = try WorktreeStateStore.load(paths) { return saved }
        let state = WorktreeState(
            id: UUID().uuidString, name: try name(of: location), project: location.projectName,
            projectRoot: location.projectRoot, path: location.worktreeRoot,
            branch: await service.currentBranch(at: location.worktreeRoot), xcode: nil, devices: [:],
            status: .ready, createdAt: Date(), hookPending: try marksHookPending(location, asked: hookPending) ? true : nil)
        // The packages first: a saved state tells other commands the checkout is set up.
        if !location.isMain { await seedPackages(into: paths, from: location.projectRoot) }
        try WorktreeStateStore.save(state, paths)
        try await service.registry.upsert(RegistryEntry(state))
        return state
    }

    /// Whether first use leaves the `post-worktree-create` hook pending: only when asked (not for the main checkout, nor
    /// for `wt create`'s own worktree); only for a checkout the registry has no entry for (one it has was set up before
    /// and lost its state, so its hook ran or had its chance); and only when the checkout's own config has the hook, or
    /// it has none yet (it then runs once the branch has one).
    func marksHookPending(_ location: ProjectLocation, asked: Bool) throws -> Bool {
        guard asked, try !service.registry.entries().contains(where: { $0.path == location.worktreeRoot }) else { return false }
        guard let own = try service.hookConfig(worktree: location.worktreeRoot, projectRoot: location.projectRoot) else {
            return true
        }
        return Self.hasHook(own)
    }

    /// Whether the config has a `post-worktree-create` hook: a command that is not empty once trimmed, as
    /// `HookRunner.run` treats it.
    static func hasHook(_ config: XcdevConfig?) -> Bool {
        guard let command = config?.hooks?.command(for: .postWorktreeCreate) else { return false }
        return !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static let waiting = "post-worktree-create hasn't run in this worktree, because it has uncommitted changes the hook could "
        + "overwrite: ask the user. It runs on the first xcd command at which the worktree has none."
    static let failedNext = "the project's post-worktree-create hook failed in this worktree (its output is in the log): "
        + "ask the user. The next xcd command at which the worktree has no uncommitted changes runs it again; to skip it in "
        + "this worktree, the user can set `hooks: { post-worktree-create: \"\" }` in its .xcdev.local.yml, which then "
        + "replaces the main checkout's .xcdev.local.yml here, so copy in any of that file's lines to keep"
    static let waitingForLock = "another xcd command holds this worktree's lock (it may be running the post-worktree-create "
        + "hook); waiting for it"

    /// Under the worktree's own lock: runs the `post-worktree-create` hook that the checkout's first command left
    /// pending, from the checkout's own config, once the worktree has no uncommitted changes. With no config of its
    /// own (a borrowed one), the hook stays pending. Says so first when another command holds the lock. Returns the
    /// state after it.
    func runPendingHook(_ ctx: WorktreeContext) async throws -> WorktreeState {
        guard ctx.state.hookPending == true, let hooks = service.hooks,
              try service.hookConfig(worktree: ctx.state.path, projectRoot: ctx.location.projectRoot) != nil else { return ctx.state }
        let lock = service.lockPath(projectRoot: ctx.location.projectRoot, worktree: ctx.state.name)
        if FileLock.isHeld(at: lock) { hooks.progress(Self.waitingForLock) }
        return try await FileLock.withLock(at: lock) { try await runPendingHookLocked(ctx, hooks: hooks) }
    }

    /// `runPendingHook`'s work, run under the worktree's lock.
    func runPendingHookLocked(_ ctx: WorktreeContext, hooks: HookRunner) async throws -> WorktreeState {
        var state = try Self.stored(ctx.paths)
        guard state.hookPending == true, let own = try service.hookConfig(worktree: state.path, projectRoot: state.projectRoot) else {
            return state
        }
        if Self.hasHook(own) {
            guard try await hasNoChanges(state.path) else {
                service.notes.add(Self.waiting)
                return state
            }
            hooks.progress("post-worktree-create hasn't run in this worktree yet, so it runs first")
            do {
                try await hooks.run(.postWorktreeCreate, config: own, context: .worktree(state, config: own, output: hooks.output),
                                    logs: ctx.paths)
            } catch var error as XcdError where error.code == .hookFailed {
                error.next = Self.failedNext
                throw error
            }
            state = try WorktreeStateStore.load(ctx.paths) ?? state
        }
        state.hookPending = nil
        try WorktreeStateStore.save(state, ctx.paths)
        return state
    }

    /// The saved state, which `wt remove` may have deleted while this command waited for the lock.
    static func stored(_ paths: WorktreePaths) throws -> WorktreeState {
        guard let state = try WorktreeStateStore.load(paths) else {
            throw XcdError(.worktreeNotFound, "this checkout's xcd state was removed while this command waited for the worktree's lock "
                           + "(by `xcd wt remove`, or by something that cleaned .xcdev/)",
                           next: "run the command again; xcd sets the checkout up again")
        }
        return state
    }

    /// Whether git sees no change in the checkout: none staged or unstaged, and no untracked file. The untracked files
    /// are listed with `--untracked-files=normal` whatever the user's `status.showUntrackedFiles`, so an agent's new
    /// files always count. `--no-optional-locks` keeps git from taking `index.lock` to refresh the index, so an agent's
    /// own `git commit` at the same moment is never refused.
    func hasNoChanges(_ root: String) async throws -> Bool {
        try await service.runner.runChecked(
            .git(["--no-optional-locks", "status", "--porcelain", "--untracked-files=normal"], in: root)).stdoutString.isEmpty
    }

    /// Copies the main checkout's resolved packages into a new worktree's `.xcdev/`. Only a speed-up: a copy that fails
    /// leaves nothing behind and a note, and the command goes on.
    func seedPackages(into paths: WorktreePaths, from projectRoot: String) async {
        do {
            try Disk.makeFolder(paths.stateDirectory)
            let ignore = paths.stateDirectory + "/.gitignore"
            if !Disk.exists(ignore) { try "*\n".write(toFile: ignore, atomically: true, encoding: .utf8) }
            try await service.seedSourcePackages(from: projectRoot, into: paths)
        } catch {
            Disk.remove(paths.partialSourcePackages)
            service.notes.add(Self.packagesNotCopied)
        }
    }

    static let packagesNotCopied = "xcd could not copy the main checkout's resolved packages into this worktree, so its "
        + "first build resolves them itself"

    /// `main` for the main checkout; the name an entry for this same checkout already has (its state was deleted);
    /// else `CheckoutName`, against every name this project's other entries hold, gone checkouts' included.
    func name(of location: ProjectLocation) throws -> String {
        if location.isMain { return "main" }
        let entries = try service.registry.entries().filter { $0.projectRoot == location.projectRoot }
        if let same = entries.first(where: { $0.path == location.worktreeRoot }) { return same.name }
        return CheckoutName.choose(for: location.worktreeRoot, held: Set(entries.map(\.name)))
    }
}
