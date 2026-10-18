/// Works out what `xcd worktree create` records as a new worktree's base: the ref its work is measured against.
struct WorktreeBase: Sendable {
    let runner: any ProcessRunning

    /// What to record for a branch made from `ref`, read in the main checkout. A branch, a remote branch, or a tag
    /// is recorded by its name (`HEAD` on a branch is that branch). Anything else, such as `HEAD~2` or part of a
    /// hash, is recorded as the commit it names now, since the same words name another commit later. Nil when
    /// git does not know the ref; a git that fails is `git_failed`.
    func recorded(for ref: String, in projectRoot: String) async throws -> String? {
        let git = GitQuery(runner: runner, directory: projectRoot)
        let full = try await git.fullName(ref)
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] {
            if let full, full.hasPrefix(prefix) { return String(full.dropFirst(prefix.count)) }
        }
        return try await git.commit(ref)
    }

    func branchExists(_ name: String, in projectRoot: String) async throws -> Bool {
        try await GitQuery(runner: runner, directory: projectRoot).commit("refs/heads/" + name) != nil
    }
}

/// What `xcd wt create` made, including the facts the report tells the user.
public struct CreatedWorktree: Sendable, Equatable {
    public var state: WorktreeState
    public var created: Bool
    public var branchCreated: Bool
    public var packagesSeeded: Bool
    public var hookRan: Bool

    public init(state: WorktreeState, created: Bool, branchCreated: Bool = false,
                packagesSeeded: Bool = false, hookRan: Bool = false) {
        self.state = state
        self.created = created
        self.branchCreated = branchCreated
        self.packagesSeeded = packagesSeeded
        self.hookRan = hookRan
    }
}

extension WorktreeService {
    /// `create`, which then records the base in the new worktree's state when it made the branch. The ref is read
    /// before the worktree is added, and written afterwards, so the worktree's `post-worktree-create` hook runs
    /// before the entry is there. A branch that already existed gets no entry: xcd does not know where it came from.
    /// A git that fails while the ref is read stops the command before anything is made.
    public func createRecordingBase(name: String, from ref: String? = nil,
                                    in ctx: WorktreeContext) async throws -> CreatedWorktree {
        let projectRoot = ctx.location.projectRoot
        let reader = WorktreeBase(runner: runner)
        let isNewBranch = try await !reader.branchExists(name, in: projectRoot)
        let base = try await reader.recorded(for: ref ?? "HEAD", in: projectRoot)
        let made = try await createTracked(name: name, from: ref, in: ctx)
        guard made.created, isNewBranch, let base else { return made }
        let state = try await FileLock.withLock(at: lockPath(projectRoot: projectRoot)) {
            let paths = WorktreePaths(root: made.state.path)
            var state = try WorktreeStateStore.load(paths) ?? made.state
            state.base = base
            try WorktreeStateStore.save(state, paths)
            return state
        }
        return CreatedWorktree(state: state, created: true, branchCreated: made.branchCreated,
                               packagesSeeded: made.packagesSeeded, hookRan: made.hookRan)
    }
}
