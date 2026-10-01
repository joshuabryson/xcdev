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
    public var locksDirectory: String { base + "/locks" }
}

public struct WorktreePaths: Sendable, Equatable {
    public let root: String

    public init(root: String) { self.root = root }

    public var stateDirectory: String { root + "/.xcdev" }
    public var stateFile: String { stateDirectory + "/worktree.json" }
    public var derivedData: String { stateDirectory + "/DerivedData" }
    public var sourcePackages: String { stateDirectory + "/SourcePackages" }
    public var logs: String { stateDirectory + "/logs" }
    public var results: String { stateDirectory + "/results" }
}
