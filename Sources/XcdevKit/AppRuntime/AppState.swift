import Foundation

public struct AppProduct: Codable, Sendable, Equatable {
    public var path: String
    public var bundleId: String
    /// Process name, used for log predicates and to find crash reports.
    public var executableName: String
    /// PLATFORM_NAME from the build settings, e.g. "iphonesimulator" or "macosx".
    public var platform: String

    public init(path: String, bundleId: String, executableName: String, platform: String) {
        self.path = path
        self.bundleId = bundleId
        self.executableName = executableName
        self.platform = platform
    }

    public var isMac: Bool { platform == "macosx" }
    public var executablePath: String { isMac ? path + "/Contents/MacOS/" + executableName : path + "/" + executableName }
}

public struct BuildRecord: Codable, Sendable, Equatable {
    public var scheme: String
    public var configuration: String?
    /// Nil when the scheme builds no app (for example a Swift package).
    public var product: AppProduct?
    public var finishedAt: Date

    public init(scheme: String, configuration: String?, product: AppProduct?, finishedAt: Date) {
        self.scheme = scheme
        self.configuration = configuration
        self.product = product
        self.finishedAt = finishedAt
    }
}

public struct LaunchRecord: Codable, Sendable, Equatable {
    public var target: String
    public var bundleId: String
    public var processName: String
    public var pid: Int32
    public var appLog: String
    public var launchedAt: Date

    public init(target: String, bundleId: String, processName: String, pid: Int32, appLog: String, launchedAt: Date) {
        self.target = target
        self.bundleId = bundleId
        self.processName = processName
        self.pid = pid
        self.appLog = appLog
        self.launchedAt = launchedAt
    }
}

/// What later commands need from earlier builds and launches in this worktree (`.xcdev/app.json`).
public struct AppState: Codable, Sendable, Equatable {
    /// Target name (a config device name, or "host" for a package built without devices) → latest successful build.
    public var builds: [String: BuildRecord]
    public var lastLaunch: LaunchRecord?

    public init(builds: [String: BuildRecord] = [:], lastLaunch: LaunchRecord? = nil) {
        self.builds = builds
        self.lastLaunch = lastLaunch
    }
}

public enum AppStateStore {
    public static func load(_ paths: WorktreePaths) throws -> AppState {
        guard let data = FileManager.default.contents(atPath: paths.appStateFile) else { return AppState() }
        do {
            return try JSONCoding.decoder.decode(AppState.self, from: data)
        } catch {
            throw XcdError(.internalError, "\(paths.appStateFile) is corrupt",
                           next: "delete \(Shell.quote(paths.appStateFile)) and run `xcd build` again",
                           details: ["\(error)"])
        }
    }

    public static func save(_ state: AppState, _ paths: WorktreePaths) throws {
        try FileManager.default.createDirectory(atPath: paths.stateDirectory, withIntermediateDirectories: true)
        let data = try JSONCoding.encoder(pretty: true).encode(state)
        try data.write(to: URL(fileURLWithPath: paths.appStateFile), options: .atomic)
    }
}
