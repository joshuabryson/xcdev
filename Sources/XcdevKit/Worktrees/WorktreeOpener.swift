import Foundation

/// Opens the checkout a command runs in: finds it, reads its config, and sets it up the first
/// time xcd sees it.
struct WorktreeOpener: Sendable {
    let service: WorktreeService

    /// Opens the worktree containing `directory`, or the project's worktree named `worktreeName`.
    /// First use of a checkout (main, or one made with plain git) initializes its state.
    func open(from directory: String, worktreeName: String?) async throws -> WorktreeContext {
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
            try await firstUse(location)
        }
        return WorktreeContext(location: location, config: loaded.config, state: state, borrowedConfig: loaded.borrowedFrom)
    }

    /// The state of a checkout xcd has not seen before, saved in it and registered.
    func firstUse(_ location: ProjectLocation) async throws -> WorktreeState {
        let state = WorktreeState(
            id: UUID().uuidString,
            name: location.isMain ? "main" : URL(fileURLWithPath: location.worktreeRoot).lastPathComponent,
            project: location.projectName, projectRoot: location.projectRoot, path: location.worktreeRoot,
            branch: await service.currentBranch(at: location.worktreeRoot), xcode: nil, devices: [:],
            status: .ready, createdAt: Date())
        try WorktreeStateStore.save(state, WorktreePaths(root: location.worktreeRoot))
        try await service.registry.upsert(RegistryEntry(state))
        return state
    }
}

extension WorktreeService {
    /// Opens the worktree containing `directory`, or the project's worktree named `worktreeName`.
    public func open(from directory: String, worktreeName: String? = nil) async throws -> WorktreeContext {
        try await WorktreeOpener(service: self).open(from: directory, worktreeName: worktreeName)
    }
}
