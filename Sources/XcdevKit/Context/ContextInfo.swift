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

    /// Reports only already-provisioned devices and already-built apps; building context never clones or builds.
    public static func build(ctx: WorktreeContext, device: String?, output: OutputFormat? = nil) -> ContextInfo {
        let provisioned = device.flatMap { ctx.state.devices[$0] }
        let product = device.flatMap { try? AppStateStore.load(ctx.paths).builds[$0]?.product }
        return ContextInfo(projectRoot: ctx.location.projectRoot, worktree: ctx.location.worktreeRoot,
                           worktreeName: ctx.state.name, device: device, udid: provisioned?.udid,
                           runtime: provisioned?.runtime, derivedData: ctx.paths.derivedData,
                           appPath: product?.path, bundleId: product?.bundleId,
                           developerDir: ctx.xcode?.developerDir, output: output?.rawValue)
    }

    /// The context of a worktree known only by its state (for worktree hooks): no device, no app.
    public static func worktree(_ state: WorktreeState, output: OutputFormat? = nil) -> ContextInfo {
        ContextInfo(projectRoot: state.projectRoot, worktree: state.path, worktreeName: state.name, device: nil, udid: nil,
                    runtime: nil, derivedData: WorktreePaths(root: state.path).derivedData, appPath: nil, bundleId: nil,
                    developerDir: state.xcode?.developerDir, output: output?.rawValue)
    }

    /// The contract's XCD_* variables. DEVELOPER_DIR is left out: it is replaced only when xcd sets one.
    public static let contractKeys: Set<String> = [
        "XCD_PROJECT_ROOT", "XCD_WORKTREE", "XCD_WORKTREE_NAME", "XCD_DEVICE", "XCD_UDID", "XCD_RUNTIME",
        "XCD_DERIVED_DATA", "XCD_APP_PATH", "XCD_BUNDLE_ID", "XCD_OUTPUT",
    ]

    /// A child's environment: `inherited` without the contract's XCD_* variables, with `overrides` merged over it.
    /// A nested xcd (inside a project command, plugin, or hook) inherits its parent's context, so a variable that
    /// doesn't apply to this child would otherwise leak the parent's value instead of being unset.
    public static func childEnvironment(inherited: [String: String], overrides: [String: String]) -> [String: String] {
        inherited.filter { !contractKeys.contains($0.key) }.merging(overrides) { $1 }
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
        return env
    }

    public var text: String {
        environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktreeName }
}
