import Foundation

/// What xcd does the first time it sees a checkout it did not make: the main checkout, or a worktree made with plain
/// git or by an agent's tool.
struct FirstUseSetup: Sendable {
    let service: WorktreeService

    /// Under the project's lock, the lock `xcd wt create` takes: names and registers the checkout, and copies the main
    /// checkout's resolved packages into a worktree. A state another command saved meanwhile is returned as it is.
    func register(_ location: ProjectLocation) async throws -> WorktreeState {
        try await FileLock.withLock(at: service.lockPath(projectRoot: location.projectRoot)) {
            try await registerHoldingLock(location)
        }
    }

    /// `register` for a caller that already holds the project's lock: `xcd wt create`, meeting a worktree of its own
    /// whose state was deleted.
    func registerHoldingLock(_ location: ProjectLocation) async throws -> WorktreeState {
        let paths = WorktreePaths(root: location.worktreeRoot)
        if let saved = try WorktreeStateStore.load(paths) { return saved }
        let state = WorktreeState(
            id: UUID().uuidString, name: try name(of: location), project: location.projectName,
            projectRoot: location.projectRoot, path: location.worktreeRoot,
            branch: await service.currentBranch(at: location.worktreeRoot), xcode: nil, devices: [:],
            status: .ready, createdAt: Date())
        // The packages first: a saved state tells other commands the checkout is set up.
        if !location.isMain { await seedPackages(into: paths, from: location.projectRoot) }
        try WorktreeStateStore.save(state, paths)
        try await service.registry.upsert(RegistryEntry(state))
        return state
    }

    /// Copies the main checkout's resolved packages into a new worktree's `.xcdev/`. Only a speed-up: a copy that fails
    /// leaves nothing behind and a note, and the command goes on.
    func seedPackages(into paths: WorktreePaths, from projectRoot: String) async {
        let existed = Disk.exists(paths.sourcePackages)
        do {
            try Disk.makeFolder(paths.stateDirectory)
            try await service.seedSourcePackages(from: projectRoot, into: paths)
        } catch {
            if !existed { Disk.remove(paths.sourcePackages) }
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
