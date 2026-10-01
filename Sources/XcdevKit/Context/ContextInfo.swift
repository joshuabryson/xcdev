/// The context contract. XCD_APP_PATH, XCD_BUNDLE_ID, and XCD_OUTPUT come later.
public struct ContextInfo: Reportable {
    public let projectRoot: String
    public let worktree: String
    public let worktreeName: String
    public let device: String?
    public let udid: String?
    public let runtime: String?
    public let derivedData: String
    public let developerDir: String?

    /// Reports only already-provisioned devices; building context never clones.
    public static func build(ctx: WorktreeContext, device: String?) -> ContextInfo {
        let provisioned = device.flatMap { ctx.state.devices[$0] }
        return ContextInfo(projectRoot: ctx.location.projectRoot, worktree: ctx.location.worktreeRoot,
                           worktreeName: ctx.state.name, device: device, udid: provisioned?.udid,
                           runtime: provisioned?.runtime, derivedData: ctx.paths.derivedData,
                           developerDir: ctx.state.xcode?.developerDir)
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
        env["DEVELOPER_DIR"] = developerDir
        return env
    }

    public var text: String {
        environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktreeName }
}
