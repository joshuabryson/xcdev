/// The context contract: the environment every project command, plugin, and hook gets.
public struct ContextInfo: Reportable {
    public let projectRoot: String
    public let worktree: String
    public let worktreeName: String
    public let device: String?
    public let udid: String?
    public let runtime: String?
    public let derivedData: String
    public let appPath: String?
    public let bundleId: String?
    public let developerDir: String?
    /// "text" or "json": the output format xcd itself was asked for, so extensions can match it.
    public let output: String?
    /// Where captures go for this worktree, branch, and device (`ui.media.dir`).
    public let mediaDir: String?

    static func media(_ config: XcdevConfig?, location: ProjectLocation, worktreeName: String, device: String?) -> String {
        MediaFolder.resolve(template: config?.mediaDirTemplate ?? XcdevConfig.defaultMediaDir, projectRoot: location.projectRoot,
                            worktreeRoot: location.worktreeRoot, worktreeName: worktreeName,
                            device: device ?? config?.defaultDevice).directory
    }

    /// Reports only already-provisioned devices and already-built apps; building context never clones or builds.
    public static func build(ctx: WorktreeContext, device: String?, output: OutputFormat? = nil) -> ContextInfo {
        let provisioned = device.flatMap { ctx.state.devices[$0] }
        let product = device.flatMap { try? AppStateStore.load(ctx.paths).builds[$0]?.product }
        return ContextInfo(projectRoot: ctx.location.projectRoot, worktree: ctx.location.worktreeRoot,
                           worktreeName: ctx.state.name, device: device, udid: provisioned?.udid,
                           runtime: provisioned?.runtime, derivedData: ctx.paths.derivedData,
                           appPath: product?.path, bundleId: product?.bundleId,
                           developerDir: ctx.xcode?.developerDir, output: output?.rawValue,
                           mediaDir: media(ctx.config, location: ctx.location, worktreeName: ctx.state.name, device: device))
    }

    /// The context before a build resolves its project, simulator, and app (for `pre-build`): the requested device's
    /// name, but no UDID, runtime, or app, even when an earlier build already has them.
    public static func beforeBuild(ctx: WorktreeContext, device: String?, output: OutputFormat? = nil) -> ContextInfo {
        ContextInfo(projectRoot: ctx.location.projectRoot, worktree: ctx.location.worktreeRoot,
                    worktreeName: ctx.state.name, device: device, udid: nil, runtime: nil,
                    derivedData: ctx.paths.derivedData, appPath: nil, bundleId: nil,
                    developerDir: ctx.xcode?.developerDir, output: output?.rawValue,
                    mediaDir: media(ctx.config, location: ctx.location, worktreeName: ctx.state.name, device: device))
    }

    /// The context of a worktree known only by its state (for worktree hooks): no device, no app.
    public static func worktree(_ state: WorktreeState, config: XcdevConfig?, output: OutputFormat? = nil) -> ContextInfo {
        let location = ProjectLocation(projectRoot: state.projectRoot, worktreeRoot: state.path)
        return ContextInfo(projectRoot: state.projectRoot, worktree: state.path, worktreeName: state.name, device: nil, udid: nil,
                    runtime: nil, derivedData: WorktreePaths(root: state.path).derivedData, appPath: nil, bundleId: nil,
                    developerDir: state.xcode?.developerDir, output: output?.rawValue,
                    mediaDir: media(config, location: location, worktreeName: state.name, device: nil))
    }

    /// The contract's XCD_* variables. DEVELOPER_DIR is left out: it is replaced only when xcd sets one.
    public static let contractKeys: Set<String> = [
        "XCD_PROJECT_ROOT", "XCD_WORKTREE", "XCD_WORKTREE_NAME", "XCD_DEVICE", "XCD_UDID", "XCD_RUNTIME",
        "XCD_DERIVED_DATA", "XCD_APP_PATH", "XCD_BUNDLE_ID", "XCD_OUTPUT", "XCD_MEDIA_DIR",
    ]

    /// What a script route's script reads its route's name from.
    public static let routeKey = "XCD_ROUTE"
    /// What a script route's script reads a parameter from, followed by the parameter's name in capitals.
    public static let paramPrefix = "XCD_PARAM_"

    /// Whether xcd sets this variable for a child: the contract's variables, and a script route's.
    static func isSetByXcd(_ name: String) -> Bool {
        contractKeys.contains(name) || name == routeKey || name.hasPrefix(paramPrefix)
    }

    /// A child's environment: `inherited` without the variables xcd sets, with `overrides` merged over it.
    /// A nested xcd (inside a project command, plugin, hook, or route script) inherits its parent's context, so a
    /// variable that doesn't apply to this child would otherwise leak the parent's value instead of being unset. A
    /// script that opens another route therefore never passes its own parameters along.
    public static func childEnvironment(inherited: [String: String], overrides: [String: String]) -> [String: String] {
        inherited.filter { !isSetByXcd($0.key) }.merging(overrides) { $1 }
    }

    public var environment: [String: String] {
        var env = [
            "XCD_PROJECT_ROOT": projectRoot,
            "XCD_WORKTREE": worktree,
            "XCD_WORKTREE_NAME": worktreeName,
            "XCD_DERIVED_DATA": derivedData,
        ]
        env["XCD_DEVICE"] = device
        env["XCD_UDID"] = udid
        env["XCD_RUNTIME"] = runtime
        env["XCD_APP_PATH"] = appPath
        env["XCD_BUNDLE_ID"] = bundleId
        env["DEVELOPER_DIR"] = developerDir
        env["XCD_OUTPUT"] = output
        env["XCD_MEDIA_DIR"] = mediaDir
        return env
    }

    public var text: String {
        environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktreeName }
}
