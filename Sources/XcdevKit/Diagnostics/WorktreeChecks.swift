import Foundation

/// Registry entries whose checkout is gone (deleted with `rm -rf` or plain `git worktree remove`).
public struct MissingWorktreesCheck: DoctorCheck {
    public let id = "missing-worktrees"
    public init() {}

    public func detect(_ env: DoctorEnvironment) async -> [DoctorProblem] {
        let unreadable = env.registryError.map { [DoctorProblem(check: id, message: $0.message, next: $0.next)] } ?? []
        return unreadable + missing(env).filter { !env.isBusy($0) }.map { entry in
            DoctorProblem(check: id, message: "\(entry.project)/\(entry.name): \(entry.path) no longer exists",
                          action: .dropRegistryEntry, fix: "drop it from the registry and prune git's record of it",
                          subject: entry.id)
        }
    }

    /// A `wt remove` between deleting the checkout and dropping its entry, or a `wt create` before its checkout exists.
    public func inProgress(_ env: DoctorEnvironment) -> [String] {
        missing(env).filter { env.isBusy($0) }.map(DoctorEnvironment.busyNote)
    }

    func missing(_ env: DoctorEnvironment) -> [RegistryEntry] {
        env.registry.filter { !FileManager.default.fileExists(atPath: $0.path) }
    }

    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws {
        guard let id = problem.subject else { return }
        try await WorktreeService(runner: env.runner, globalPaths: env.globalPaths).dropMissing(id: id)
    }
}

/// Worktrees an interrupted `xcd wt create` left half-made.
public struct IncompleteWorktreesCheck: DoctorCheck {
    public let id = "incomplete-worktrees"
    public init() {}

    public func detect(_ env: DoctorEnvironment) async -> [DoctorProblem] {
        incomplete(env).filter { !env.isBusy($0) }.map { entry in
            DoctorProblem(check: id, message: "\(entry.project)/\(entry.name) at \(entry.path) was left half-created by an interrupted `xcd wt create`",
                          action: .discardWorktree, fix: "remove it if it is clean and xcd's (otherwise only its registry entry)",
                          subject: entry.id)
        }
    }

    /// A `wt create` still running, most likely its post-worktree-create hook.
    public func inProgress(_ env: DoctorEnvironment) -> [String] {
        incomplete(env).filter { env.isBusy($0) }.map(DoctorEnvironment.busyNote)
    }

    func incomplete(_ env: DoctorEnvironment) -> [RegistryEntry] {
        env.registry.filter { $0.status == .incomplete && FileManager.default.fileExists(atPath: $0.path) }
    }

    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws {
        guard let id = problem.subject else { return }
        try await WorktreeService(runner: env.runner, globalPaths: env.globalPaths).discardIncomplete(id: id)
    }
}

extension WorktreeService {
    /// Drops the registry entry of a worktree whose checkout is gone, and prunes git's record of it. Does nothing
    /// if the entry was removed meanwhile or its checkout exists again.
    func dropMissing(id: String) async throws {
        guard let entry = try registry.entries().first(where: { $0.id == id }) else { return }
        try await whileUnused(entry) {
            guard let current = try registry.entries().first(where: { $0.id == id }),
                  !FileManager.default.fileExists(atPath: current.path) else { return }
            if FileManager.default.fileExists(atPath: current.projectRoot) {
                _ = try? await runner.run(.git(["worktree", "prune"], in: current.projectRoot))
            }
            try await registry.remove(id: id)
        }
    }

    /// Removes a half-created worktree; does nothing if the entry was completed or removed meanwhile.
    func discardIncomplete(id: String) async throws {
        guard let entry = try registry.entries().first(where: { $0.id == id }) else { return }
        try await whileUnused(entry) {
            guard let current = try registry.entries().first(where: { $0.id == id }), current.status == .incomplete else { return }
            try await discardStale(current, projectRoot: current.projectRoot)
        }
    }

    /// Runs `body` holding the worktree's lock and then the project's, the order `create` and `remove` take them.
    /// The worktree's lock is taken without waiting: `create` and `remove` hold it through their hooks (up to 30
    /// minutes), so a held lock means one is running, and the worktree is left to it (`DoctorLeftAlone`). `body`
    /// must re-read the entry, since the caller looked at it without the locks.
    private func whileUnused(_ entry: RegistryEntry, _ body: () async throws -> Void) async throws {
        let ran: Void? = try await FileLock.withLockIfFree(at: lockPath(projectRoot: entry.projectRoot, worktree: entry.name)) {
            try await FileLock.withLock(at: lockPath(projectRoot: entry.projectRoot)) { try await body() }
        }
        guard ran != nil else { throw DoctorLeftAlone(note: DoctorEnvironment.busyNote(entry)) }
    }
}
