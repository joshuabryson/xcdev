public struct XcdevConfig: Codable, Sendable, Equatable {
    public var version: Int
    public var project: String
    public var xcode: String?
    public var schemes: Schemes?
    public var defaultDevice: String?
    public var devices: [String: DeviceSpec]?
    public var presets: [String: LaunchPreset]?
    public var worktrees: WorktreeSettings?
    public var logs: LogSettings?

    public struct Schemes: Codable, Sendable, Equatable {
        public var app: String?
        public var test: String?
    }

    public struct WorktreeSettings: Codable, Sendable, Equatable {
        public var root: String?
    }

    public struct LogSettings: Codable, Sendable, Equatable {
        public var maxFollow: String?
    }

    public var allDevices: [String: DeviceSpec] { devices ?? [:] }
    public var worktreesRoot: String { worktrees?.root ?? "../{project}.worktrees" }

    /// Longest `xcd logs --follow --for` allowed, so an agent can never block for long. Default 5 minutes.
    public var maxLogFollow: Duration { logs?.maxFollow.flatMap(DurationText.parse) ?? .seconds(300) }
}

public struct DeviceSpec: Codable, Sendable, Equatable {
    public var type: String?
    public var runtime: String?
    public var platform: String?
    public var pairWith: String?

    public init(type: String? = nil, runtime: String? = nil, platform: String? = nil, pairWith: String? = nil) {
        self.type = type
        self.runtime = runtime
        self.platform = platform
        self.pairWith = pairWith
    }

    public var isMac: Bool { platform == "macOS" }
}

public struct LaunchPreset: Codable, Sendable, Equatable {
    public var args: [String]?
    public var env: [String: String]?
}
