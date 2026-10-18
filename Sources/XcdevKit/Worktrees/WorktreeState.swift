import Foundation

public struct ProvisionedDevice: Codable, Sendable, Equatable {
    public var udid: String
    public var deviceType: String
    public var deviceTypeIdentifier: String
    public var runtime: String
    public var runtimeIdentifier: String
    /// For watches: the udid of the phone this clone is paired with, once the pairing succeeded.
    public var pairedWith: String?

    public init(udid: String, deviceType: String, deviceTypeIdentifier: String, runtime: String, runtimeIdentifier: String,
                pairedWith: String? = nil) {
        self.udid = udid
        self.deviceType = deviceType
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.runtime = runtime
        self.runtimeIdentifier = runtimeIdentifier
        self.pairedWith = pairedWith
    }
}

public struct WorktreeState: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case ready, incomplete }

    public var id: String
    public var name: String
    public var project: String
    public var projectRoot: String
    public var path: String
    public var branch: String?
    /// Pinned on first use; never changes afterwards.
    public var xcode: XcodeInstall?
    /// Config device name → this worktree's clone. Runtime is pinned at clone time.
    public var devices: [String: ProvisionedDevice]
    public var status: Status
    public var createdAt: Date
    /// The ref this worktree's work is measured against, recorded by `xcd worktree create` when it makes the
    /// branch. Absent for the main checkout, a reused branch, and state written before this.
    public var base: String?
    /// True while the `post-worktree-create` hook of a worktree xcd did not make has not run. Absent for the main
    /// checkout, for worktrees `xcd worktree create` made, and in state written before this.
    public var hookPending: Bool?

    public init(id: String, name: String, project: String, projectRoot: String, path: String, branch: String?,
                xcode: XcodeInstall?, devices: [String: ProvisionedDevice], status: Status, createdAt: Date,
                base: String? = nil, hookPending: Bool? = nil) {
        self.id = id
        self.name = name
        self.project = project
        self.projectRoot = projectRoot
        self.path = path
        self.branch = branch
        self.xcode = xcode
        self.devices = devices
        self.status = status
        self.createdAt = createdAt
        self.base = base
        self.hookPending = hookPending
    }
}

public enum WorktreeStateStore {
    public static func load(_ paths: WorktreePaths) throws -> WorktreeState? {
        guard let data = FileManager.default.contents(atPath: paths.stateFile) else { return nil }
        do {
            return try JSONCoding.decoder.decode(WorktreeState.self, from: data)
        } catch {
            throw XcdError(.internalError, "\(paths.stateFile) is corrupt",
                           next: "delete \(Shell.quote(paths.stateFile)) and re-run; xcd will re-create it",
                           details: ["\(error)"])
        }
    }

    /// Writes atomically. `.xcdev/` ignores itself, so git never sees state even without `xcd init`.
    public static func save(_ state: WorktreeState, _ paths: WorktreePaths) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: paths.stateDirectory, withIntermediateDirectories: true)
        let ignore = paths.stateDirectory + "/.gitignore"
        if !fm.fileExists(atPath: ignore) { try "*\n".write(toFile: ignore, atomically: true, encoding: .utf8) }
        let data = try JSONCoding.encoder(pretty: true).encode(state)
        try data.write(to: URL(fileURLWithPath: paths.stateFile), options: .atomic)
    }
}
