public struct SchemaField: Sendable {
    public let name: String
    public let node: SchemaNode
    public let required: Bool
    /// What applies when the key is absent, in words ("latest", "the Xcode xcode-select points to"). Nil: no default.
    public let defaultValue: String?
    /// A YAML snippet that sets this key, shown by `xcd config explain`.
    public let example: String

    public init(_ name: String, _ node: SchemaNode, required: Bool = false, default defaultValue: String? = nil,
                example: String) {
        self.name = name
        self.node = node
        self.required = required
        self.defaultValue = defaultValue
        self.example = example
    }
}

/// Structural description of the config, and the single source of truth for per-key documentation:
/// `xcd config schema`, `xcd config explain`, and validation all read it.
public indirect enum SchemaNode: Sendable {
    case string(String, allowed: [String]? = nil)
    case integer(String)
    case boolean(String)
    case stringList(String)
    case stringMap(String)
    case object(String, [SchemaField])
    /// User-named keys (e.g. device names), each validated against the value schema.
    case map(String, SchemaNode)
    /// A key kept for a later version. Using it is an error that says what it is kept for. It is left out of
    /// `xcd config explain` and the JSON schema.
    case reserved(String)

    public var summary: String {
        switch self {
        case .string(let d, _), .integer(let d), .boolean(let d), .stringList(let d), .stringMap(let d),
             .object(let d, _), .map(let d, _), .reserved(let d):
            return d
        }
    }

    var isReserved: Bool {
        if case .reserved = self { return true }
        return false
    }
}

public enum ConfigSchema {
    public static let v1: SchemaNode = .object("xcdev project configuration (.xcdev.yml).", [
        SchemaField("version", .integer("Config format version. Must be 1."), required: true, example: "version: 1"),
        SchemaField("project", .string("Path to the .xcworkspace, .xcodeproj, or Package.swift, relative to the project root."),
                    required: true, example: "project: App.xcworkspace"),
        SchemaField("xcode", .string("Which Xcode to use: a version (\"27.0\", \"27\"), \"latest\", \"beta\", \"system\", or an absolute path to an Xcode .app. Pinned per worktree on first use; `--xcode` overrides it for one command."),
                    default: "system (the Xcode xcode-select points to)", example: "xcode: \"27.0\""),
        SchemaField("schemes", .object("Default schemes.", [
            SchemaField("app", .string("Scheme used by build and run."),
                        default: "the project's only scheme, if it has exactly one", example: "schemes:\n  app: App"),
            SchemaField("test", .string("Scheme used by test."), default: "schemes.app",
                        example: "schemes:\n  test: AppTests"),
        ]), example: "schemes:\n  app: App\n  test: AppTests"),
        SchemaField("defaultDevice", .string("Device (a key under devices) used when --device is omitted."),
                    default: "the only device, if exactly one is configured", example: "defaultDevice: iphone"),
        SchemaField("devices", .map("Named devices. Each simulator device gets its own clone per worktree, created on first use.", .object("A device.", [
            SchemaField("type", .string("Simulator device type name or identifier, e.g. \"iPhone 18 Pro\". Required unless platform is macOS. `xcrun simctl list devicetypes` lists them."),
                        example: "devices:\n  iphone: { type: \"iPhone 18 Pro\" }"),
            SchemaField("runtime", .string("\"latest\", a runtime name like \"iOS 26.5\", or a version like \"26.5\". Pinned per worktree when first cloned."),
                        default: "latest (the newest installed runtime this Xcode supports)",
                        example: "devices:\n  iphone: { type: \"iPhone 18 Pro\", runtime: \"iOS 26.5\" }"),
            SchemaField("platform", .string("Set to macOS for Mac apps. They build and run natively and have no simulator.", allowed: ["macOS"]),
                        example: "devices:\n  mac: { platform: macOS }"),
            SchemaField("pairWith", .string("For watch devices: the phone device (a key under devices) to pair with."),
                        example: "devices:\n  watch: { type: \"Apple Watch Series 11 (46mm)\", pairWith: iphone }"),
        ])), example: "devices:\n  iphone: { type: \"iPhone 18 Pro\", runtime: latest }\n  mac: { platform: macOS }"),
        SchemaField("presets", .map("Named launch configurations for `xcd run --preset`.", .object("A launch preset.", [
            SchemaField("args", .stringList("Launch arguments passed to the app."),
                        example: "presets:\n  onboarding: { args: [\"-resetOnboarding\", \"YES\"] }"),
            SchemaField("env", .stringMap("Environment variables set for the app."),
                        example: "presets:\n  staging: { env: { API_ENV: staging } }"),
        ])), example: "presets:\n  onboarding:\n    args: [\"-resetOnboarding\", \"YES\"]\n    env: { API_ENV: staging }"),
        SchemaField("worktrees", .object("Worktree settings.", [
            SchemaField("root", .string("Directory for new worktrees, relative to the project root. {project} expands to the project directory name."),
                        default: "../{project}.worktrees", example: "worktrees:\n  root: \"../{project}.worktrees\""),
        ]), example: "worktrees:\n  root: \"../{project}.worktrees\""),
        SchemaField("logs", .object("Log settings.", [
            SchemaField("maxFollow", .string("Longest time `xcd logs --follow --for` may run, e.g. \"5m\". Keeps agents from blocking on a log stream."),
                        default: "5m", example: "logs:\n  maxFollow: 10m"),
        ]), example: "logs:\n  maxFollow: 10m"),
        SchemaField("commands", .map("Project commands, run as `xcd <name> [args…]`. Extra arguments are passed to the script. Built-in commands win over project commands, which win over plugins.", .object("A project command.", [
            SchemaField("description", .string("One line that `xcd help` shows next to the command."),
                        example: "commands:\n  seed-db:\n    description: \"Load fixture data into the running app's container\"\n    run: ./scripts/seed.sh"),
            SchemaField("run", .string("Shell command run from the worktree root with the XCD_* context variables set. Extra arguments are appended."),
                        required: true, example: "commands:\n  seed-db: { run: ./scripts/seed.sh }"),
            SchemaField("needs", .stringList("What must be ready before the command runs: device (the device's clone exists and is booted) and build (a successful build exists; xcd builds first if not). The device is defaultDevice, or $XCD_DEVICE when set."),
                        default: "nothing", example: "commands:\n  seed-db: { run: ./scripts/seed.sh, needs: [device, build] }"),
            SchemaField("timeout", .string("Longest the command may run, e.g. \"10m\"."), default: "30m",
                        example: "commands:\n  seed-db: { run: ./scripts/seed.sh, timeout: 10m }"),
        ])), example: "commands:\n  seed-db:\n    description: \"Load fixture data\"\n    run: ./scripts/seed.sh\n    needs: [device]"),
        SchemaField("hooks", .object("Shell commands xcd runs at fixed points, from the worktree root with the XCD_* context variables set. A hook that exits non-zero aborts the command with hook_failed. Output goes to .xcdev/logs/.", [
            SchemaField("post-worktree-create", .string("Runs in a new worktree at the end of `xcd wt create`. If it fails, the worktree is rolled back."),
                        example: "hooks:\n  post-worktree-create: ./scripts/bootstrap.sh"),
            SchemaField("pre-build", .string("Runs before every build, including the builds of `xcd test` and `xcd run`."),
                        example: "hooks:\n  pre-build: swiftgen"),
            SchemaField("post-launch", .string("Runs right after `xcd run` or `xcd launch` starts the app, before the crash window. XCD_UDID and XCD_BUNDLE_ID are set."),
                        example: "hooks:\n  post-launch: ./scripts/grant-permissions.sh"),
            SchemaField("pre-worktree-remove", .string("Runs in the worktree at the start of `xcd wt remove`, before anything is deleted; not for a checkout xcd did not make, which `wt remove` leaves in place."),
                        example: "hooks:\n  pre-worktree-remove: ./scripts/teardown.sh"),
        ]), example: "hooks:\n  pre-build: swiftgen\n  post-launch: ./scripts/grant-permissions.sh"),
        SchemaField("ui", .object("Screenshots, screen recordings, and the media folder they go to.", [
            SchemaField("media", .object("Where captures go.", [
                SchemaField("dir", .string("Folder for screenshots, recordings, and other captures. A relative path starts at the main checkout, so every worktree's captures land in one tree that `xcd wt remove` keeps. Placeholders: {project}, {worktree}, {branch} (a/b becomes nested folders; a detached HEAD is detached-<commit>), and {device}. `--out` overrides it for one command."),
                            default: XcdevConfig.defaultMediaDir,
                            example: "ui:\n  media:\n    dir: \".xcdev-media/{worktree}/{branch}\""),
            ]), example: "ui:\n  media:\n    dir: \".xcdev-media/{worktree}/{branch}\""),
            SchemaField("record", .object("Screen recording settings.", [
                SchemaField("maxDuration", .string("Longest a recording may run, e.g. \"10m\". The next `xcd sim`, `xcd ui`, `xcd run`, `xcd launch`, or `xcd test` in the worktree stops a longer one cleanly and keeps the video."),
                            default: "10m", example: "ui:\n  record:\n    maxDuration: 5m"),
            ]), example: "ui:\n  record:\n    maxDuration: 5m"),
        ]), example: "ui:\n  media:\n    dir: \".xcdev-media/{worktree}/{branch}\"\n  record:\n    maxDuration: 10m"),
        SchemaField("deeplinks", deeplinks, example: "deeplinks:\n  vars:\n    base: \"myapp://app\"\n  routes:\n    settings:\n      description: \"Open settings\"\n      url: \"{base}/settings\""),
        SchemaField("lint", lint, example: "lint:\n  tool: swiftlint\n  args: [\"--strict\"]"),
        SchemaField("format", format, example: "format:\n  tool: swiftformat"),
    ])

    /// Top-level keys defined later. Present keys get a clear "not supported yet" error.
    public static let reservedTopLevelKeys = ["debug"]
}
