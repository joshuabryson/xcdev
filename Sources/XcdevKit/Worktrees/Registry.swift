import Foundation

public struct RegistryEntry: Codable, Sendable, Equatable {
    public var id: String
    public var project: String
    public var projectRoot: String
    public var name: String
    public var path: String
    public var status: WorktreeState.Status

    public init(_ state: WorktreeState) {
        id = state.id
        project = state.project
        projectRoot = state.projectRoot
        name = state.name
        path = state.path
        status = state.status
    }
}

/// Every worktree xcd knows about, across projects. Used for `wt list --all` and orphan detection.
public struct Registry: Sendable {
    public let paths: GlobalPaths

    public init(paths: GlobalPaths) { self.paths = paths }

    private struct File: Codable {
        var version = 1
        var worktrees: [RegistryEntry]
    }

    public func entries() throws -> [RegistryEntry] {
        guard let data = FileManager.default.contents(atPath: paths.registryFile) else { return [] }
        do {
            return try JSONCoding.decoder.decode(File.self, from: data).worktrees
        } catch {
            throw XcdError(.internalError, "\(paths.registryFile) is corrupt", details: ["\(error)"])
        }
    }

    /// Replaces an entry with the same id, or the same project root and name.
    public func upsert(_ entry: RegistryEntry) async throws {
        try await mutate { entries in
            entries.removeAll { $0.id == entry.id || ($0.projectRoot == entry.projectRoot && $0.name == entry.name) }
            entries.append(entry)
        }
    }

    public func remove(id: String) async throws {
        try await mutate { $0.removeAll { $0.id == id } }
    }

    private func mutate(_ change: @Sendable (inout [RegistryEntry]) -> Void) async throws {
        try await FileLock.withLock(at: paths.locksDirectory + "/registry.lock") {
            var current = try entries()
            change(&current)
            current.sort { ($0.projectRoot, $0.name) < ($1.projectRoot, $1.name) }
            let data = try JSONCoding.encoder(pretty: true).encode(File(worktrees: current))
            try data.write(to: URL(fileURLWithPath: paths.registryFile), options: .atomic)
        }
    }
}
