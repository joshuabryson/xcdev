import Foundation

public struct GlobalPaths: Sendable, Equatable {
    public let base: String

    public init(base: String) { self.base = base }

    /// `XCDEV_HOME` overrides the default `~/Library/Application Support/xcdev` (used by tests).
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> GlobalPaths {
        if let custom = environment["XCDEV_HOME"], !custom.isEmpty { return GlobalPaths(base: custom) }
        return GlobalPaths(base: NSHomeDirectory() + "/Library/Application Support/xcdev")
    }

    public var registryFile: String { base + "/registry.json" }
    public var cacheDirectory: String { base + "/cache" }
    public var locksDirectory: String { base + "/locks" }
    /// One folder per simulator clone with a booted session: its lease, lock, and watchdog record.
    public var devicesDirectory: String { base + "/devices" }
}

public struct WorktreePaths: Sendable, Equatable {
    public let root: String

    public init(root: String) { self.root = root }

    public var stateDirectory: String { root + "/.xcdev" }
    public var stateFile: String { stateDirectory + "/worktree.json" }
    public var derivedData: String { stateDirectory + "/DerivedData" }
    public var sourcePackages: String { stateDirectory + "/SourcePackages" }
    /// Where the packages are copied to before they are moved to `sourcePackages`.
    public var partialSourcePackages: String { sourcePackages + ".partial" }
    public var logs: String { stateDirectory + "/logs" }
    public var results: String { stateDirectory + "/results" }
    /// The re-signed copies of Mac apps that `isolation: suffix` launches, one `<App>.app` each.
    public var macCopies: String { stateDirectory + "/mac" }

    public var appStateFile: String { stateDirectory + "/app.json" }

    /// `<directory>/<yyyyMMdd-HHmmss>-<kind>.<ext>`, suffixed `-2`, `-3`, … if taken. Creates `directory`.
    public func newArtifact(in directory: String, kind: String, ext: String, now: Date) -> String {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = directory + "/" + formatter.string(from: now) + "-" + kind
        var candidate = stem + "." + ext
        var n = 2
        while fm.fileExists(atPath: candidate) {
            candidate = "\(stem)-\(n).\(ext)"
            n += 1
        }
        return candidate
    }
}
