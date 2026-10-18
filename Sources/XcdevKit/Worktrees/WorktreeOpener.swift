import Foundation

/// Opens the checkout a command runs in: finds it, reads its config, and sets it up the first
/// time xcd sees it.
struct WorktreeOpener: Sendable {
    let service: WorktreeService

    /// Opens the worktree containing `directory`, or the project's worktree named `worktreeName`.
    /// First use of a checkout (main, or one made with plain git) initializes its state. `runsPendingHook` is false for
    /// commands that only look (`wt`, `config`, `context`) and inside a hook.
    func open(from directory: String, worktreeName: String?, runsPendingHook: Bool) async throws -> WorktreeContext {
        var location = try await WorktreeLocator(runner: service.runner).locate(from: directory)
        if let worktreeName {
            let root = worktreeName == "main"
                ? location.projectRoot
                : try service.entry(named: worktreeName, projectRoot: location.projectRoot).path
            guard Disk.exists(root) else {
                throw XcdError(.worktreeNotFound, "worktree '\(worktreeName)' was deleted outside xcd",
                               next: "run `xcd wt remove \(worktreeName)` to clean it up")
            }
            location = ProjectLocation(projectRoot: location.projectRoot, worktreeRoot: root)
        }
        let loaded = try ConfigLoader.checkout(worktreeRoot: location.worktreeRoot, projectRoot: location.projectRoot)
        if let note = loaded.note { service.notes.add(note) }
        let state = if let saved = try WorktreeStateStore.load(WorktreePaths(root: location.worktreeRoot)) {
            saved
        } else {
            try await FirstUseSetup(service: service).register(location)
        }
        var ctx = WorktreeContext(location: location, config: loaded.config, state: state, borrowedConfig: loaded.borrowedFrom)
        if runsPendingHook { ctx.state = try await FirstUseSetup(service: service).runPendingHook(ctx) }
        return ctx
    }
}

extension WorktreeService {
    /// Opens the worktree containing `directory`, or the project's worktree named `worktreeName`, running a pending
    /// `post-worktree-create` hook unless `runsPendingHook` is false.
    public func open(from directory: String, worktreeName: String? = nil, runsPendingHook: Bool = true) async throws -> WorktreeContext {
        try await WorktreeOpener(service: self).open(from: directory, worktreeName: worktreeName, runsPendingHook: runsPendingHook)
    }
}
