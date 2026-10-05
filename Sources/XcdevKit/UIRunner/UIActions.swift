import Foundation

/// One action for the runner, and what its errors call it and the thing it acts on.
struct ActionCall<Request: Encodable> {
    let path: String
    let request: Request
    /// "tap", "swipe", "typing", …
    let what: String
    /// The target as the user gave it, or what stands in for one ("the screen").
    let target: String
    var slack: Duration = .seconds(30)
}

/// An action the runner carried out, ready to be reported.
struct ActionDone {
    let result: ActionResult
    let session: RunnerSession
    let worktree: String
    let treeAsked: Bool

    func report(_ action: String, target: String, detail: String? = nil) -> UIActionReport {
        var report = UIActionReport(action: action, target: target, element: result.element, x: result.x, y: result.y, ms: result.ms,
                                    restarted: session.restarted, device: session.device, udid: session.udid, worktree: worktree)
        report.toX = result.toX
        report.toY = result.toY
        report.method = result.method
        report.detail = detail
        report.tree = result.tree
        if treeAsked, result.tree == nil { report.notes = ["note: the tree could not be read after the action; run `xcd ui tree`"] }
        return report
    }
}

/// `xcd ui long-press`, `swipe`, `type`, `button`, and `rotate`, and what every action shares.
extension UIService {
    /// Sends an action and returns what the runner did. An action is never sent twice. When the runner says the app is
    /// gone, the error carries the app's crash report if one was written.
    func act<Request: Encodable>(_ call: ActionCall<Request>, _ options: UIOptions, in ctx: inout WorktreeContext) async throws -> ActionDone {
        let started = now()
        let exchange = RunnerExchange(path: call.path, request: call.request, what: call.what, resend: false, slack: call.slack)
        let (session, result) = try await send(exchange, as: ActionResult.self, options, in: &ctx)
        switch result {
        case .success(let action):
            return ActionDone(result: action, session: session, worktree: ctx.state.name, treeAsked: options.tree)
        case .failure(let failure) where failure.code == RunnerFailure.Code.appCrashed:
            throw await crashed(during: call.what, since: started, options, in: ctx)
        case .failure(let failure):
            throw UIRunnerErrors.error(failure, target: call.target, timeout: options.effectiveTimeout)
        }
    }

    /// The error for an action that left the app no longer running. The report is looked for by the built app's
    /// process name, for up to three seconds: it is written a moment after the crash. Another `--bundle` has no name
    /// to look for.
    func crashed(during what: String, since: Date, _ options: UIOptions, in ctx: WorktreeContext) async -> XcdError {
        let device = try? supervisor.provisioner.deviceName(options.device, config: ctx.config)
        let product = device.flatMap { (try? AppStateStore.load(ctx.paths))?.builds[$0]?.product }
        var report: CrashReport?
        if let product, options.bundle == nil || options.bundle == product.bundleId {
            for _ in 0..<6 where report == nil {
                report = crashes.find(processName: product.executableName, since: since)
                if report == nil { try? await supervisor.sleep(.milliseconds(500)) }
            }
        }
        guard let report else {
            return XcdError(.appCrashed, "the app stopped running during the \(what) (no crash report found)",
                            next: "see its last output with `xcd logs --app`, then start it again with `xcd run`")
        }
        let summary = [report.exception, report.termination].compactMap { $0 }.joined(separator: ", ")
        return XcdError(.appCrashed, "the app crashed during the \(what)" + (summary.isEmpty ? "" : ": \(summary)"),
                        next: "fix the crash, then start the app again with `xcd run`",
                        details: report.frames.map { "  " + $0 } + ["report: \(report.path)"])
    }

    func scope(_ options: UIOptions, in ctx: WorktreeContext) throws -> ActionScope {
        ActionScope(bundleId: try bundleId(options, in: ctx), system: options.system,
                    timeout: DurationText.seconds(options.effectiveTimeout), tree: options.tree)
    }
}
