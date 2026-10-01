import Foundation

public struct ProvisionedDevice: Codable, Sendable, Equatable {
    public var udid: String
    public var deviceType: String
    public var deviceTypeIdentifier: String
    public var runtime: String
    public var runtimeIdentifier: String

    public init(udid: String, deviceType: String, deviceTypeIdentifier: String, runtime: String, runtimeIdentifier: String) {
        self.udid = udid
        self.deviceType = deviceType
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.runtime = runtime
        self.runtimeIdentifier = runtimeIdentifier
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

    public init(id: String, name: String, project: String, projectRoot: String, path: String, branch: String?,
                xcode: XcodeInstall?, devices: [String: ProvisionedDevice], status: Status, createdAt: Date) {
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
