public struct SchemaField: Sendable {
    public let name: String
    public let node: SchemaNode
    public let required: Bool

    public init(_ name: String, _ node: SchemaNode, required: Bool = false) {
        self.name = name
        self.node = node
        self.required = required
    }
}

/// Structural description of the config. Also the single source of truth for per-key
/// descriptions (`xcd config schema` now, `xcd config explain` later).
public indirect enum SchemaNode: Sendable {
    case string(String, allowed: [String]? = nil)
    case integer(String)
    case stringList(String)
    case stringMap(String)
    case object(String, [SchemaField])
    /// User-named keys (e.g. device names), each validated against the value schema.
    case map(String, SchemaNode)

    public var summary: String {
        switch self {
        case .string(let d, _), .integer(let d), .stringList(let d), .stringMap(let d),
             .object(let d, _), .map(let d, _):
            return d
        }
    }
}

public enum ConfigSchema {
    public static let v1: SchemaNode = .object("xcdev project configuration (.xcdev.yml).", [
        SchemaField("version", .integer("Config format version. Must be 1."), required: true),
        SchemaField("project", .string("Path to the .xcworkspace, .xcodeproj, or Package.swift, relative to the project root."), required: true),
        SchemaField("xcode", .string("Which Xcode to use: a version (\"27.0\", \"27\"), \"latest\", \"beta\", \"system\", or an absolute path to an Xcode .app. Default: the Xcode xcode-select points to. Pinned per worktree on first use.")),
        SchemaField("schemes", .object("Default schemes.", [
            SchemaField("app", .string("Scheme used by build and run.")),
            SchemaField("test", .string("Scheme used by test.")),
        ])),
        SchemaField("defaultDevice", .string("Device (a key under devices) used when --device is omitted.")),
        SchemaField("devices", .map("Named devices. Each simulator device gets its own clone per worktree, created on first use.", .object("A device.", [
            SchemaField("type", .string("Simulator device type name or identifier, e.g. \"iPhone 18 Pro\". Required unless platform is macOS.")),
            SchemaField("runtime", .string("\"latest\" (default), a runtime name like \"iOS 26.5\", or a version like \"26.5\". Pinned per worktree when first cloned.")),
            SchemaField("platform", .string("Set to macOS for Mac apps. They build and run natively and have no simulator.", allowed: ["macOS"])),
            SchemaField("pairWith", .string("For watch devices: the phone device (a key under devices) to pair with.")),
        ]))),
        SchemaField("presets", .map("Named launch configurations for `xcd run --preset`.", .object("A launch preset.", [
            SchemaField("args", .stringList("Launch arguments passed to the app.")),
            SchemaField("env", .stringMap("Environment variables set for the app.")),
        ]))),
        SchemaField("worktrees", .object("Worktree settings.", [
            SchemaField("root", .string("Directory for new worktrees, relative to the project root. {project} expands to the project directory name. Default: ../{project}.worktrees")),
        ])),
        SchemaField("logs", .object("Log settings.", [
            SchemaField("maxFollow", .string("Longest time `xcd logs --follow --for` may run, e.g. \"5m\". Keeps agents from blocking on a log stream. Default: 5m")),
        ])),
    ])

    /// Top-level keys defined later. Present keys get a clear "not supported yet" error.
    public static let reservedTopLevelKeys = ["commands", "hooks", "deeplinks", "lint", "ui", "debug"]
}
