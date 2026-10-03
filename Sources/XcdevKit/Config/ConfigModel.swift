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
    public var commands: [String: ProjectCommandSpec]?
    public var hooks: HookCommands?
    public var ui: UISettings?

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

    /// `ui:`: screenshots, recordings, and (later) UI driving.
    public struct UISettings: Codable, Sendable, Equatable {
        public var media: Media?
        public var record: Record?

        public struct Media: Codable, Sendable, Equatable {
            public var dir: String?
        }

        public struct Record: Codable, Sendable, Equatable {
            public var maxDuration: String?
        }
    }

    /// Where captures go when `ui.media.dir` is absent (see `MediaFolder`).
    public static let defaultMediaDir = ".xcdev-media/{worktree}/{branch}"
    /// The placeholders `ui.media.dir` may use.
    public static let mediaPlaceholders = ["project", "worktree", "branch", "device"]

    public var allDevices: [String: DeviceSpec] { devices ?? [:] }
    public var worktreesRoot: String { worktrees?.root ?? "../{project}.worktrees" }

    /// Longest `xcd logs --follow --for` allowed, so an agent can never block for long. Default 5 minutes.
    public var maxLogFollow: Duration { logs?.maxFollow.flatMap(DurationText.parse) ?? .seconds(300) }

    public var mediaDirTemplate: String { ui?.media?.dir ?? Self.defaultMediaDir }

    /// Longest a recording may run before the next `sim`, `ui`, `run`, `launch`, or `test` command stops it. Default 10m.
    public var maxRecording: Duration { ui?.record?.maxDuration.flatMap(DurationText.parse) ?? .seconds(600) }
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

/// A project command under `commands:`, run as `xcd <name> [args…]`.
public struct ProjectCommandSpec: Codable, Sendable, Equatable {
    public var description: String?
    public var run: String
    /// "device" and/or "build".
    public var needs: [String]?
    public var timeout: String?

    public init(description: String? = nil, run: String, needs: [String]? = nil, timeout: String? = nil) {
        self.description = description
        self.run = run
        self.needs = needs
        self.timeout = timeout
    }

    public static let needsValues = ["device", "build"]
    public static let defaultTimeout: Duration = .seconds(1800)

    public var needsDevice: Bool { needs?.contains("device") ?? false }
    public var needsBuild: Bool { needs?.contains("build") ?? false }
    public var timeoutDuration: Duration { timeout.flatMap(DurationText.parse) ?? Self.defaultTimeout }
}

/// The hooks v1 supports, named as they appear under `hooks:`.
public enum HookName: String, Codable, Sendable, CaseIterable {
    case postWorktreeCreate = "post-worktree-create"
    case preBuild = "pre-build"
    case postLaunch = "post-launch"
    case preWorktreeRemove = "pre-worktree-remove"
}

/// `hooks:`: one shell command per hook.
public struct HookCommands: Codable, Sendable, Equatable {
    public var postWorktreeCreate: String?
    public var preBuild: String?
    public var postLaunch: String?
    public var preWorktreeRemove: String?

    enum CodingKeys: String, CodingKey {
        case postWorktreeCreate = "post-worktree-create"
        case preBuild = "pre-build"
        case postLaunch = "post-launch"
        case preWorktreeRemove = "pre-worktree-remove"
    }

    public init(postWorktreeCreate: String? = nil, preBuild: String? = nil, postLaunch: String? = nil,
                preWorktreeRemove: String? = nil) {
        self.postWorktreeCreate = postWorktreeCreate
        self.preBuild = preBuild
        self.postLaunch = postLaunch
        self.preWorktreeRemove = preWorktreeRemove
    }

    public func command(for hook: HookName) -> String? {
        switch hook {
        case .postWorktreeCreate: return postWorktreeCreate
        case .preBuild: return preBuild
        case .postLaunch: return postLaunch
        case .preWorktreeRemove: return preWorktreeRemove
        }
    }
}
