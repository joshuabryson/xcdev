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

/// What `xcd ui swipe` was given: a direction (and maybe an element), or two points.
public struct SwipeOptions: Sendable {
    public var direction: String?
    public var on: String?
    public var from: String?
    public var to: String?

    public init(direction: String?, on: String?, from: String?, to: String?) {
        self.direction = direction
        self.on = on
        self.from = from
        self.to = to
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

    public func longPress(_ target: String, duration: Duration, _ options: UIOptions,
                          in ctx: inout WorktreeContext) async throws -> UIActionReport {
        guard duration >= .milliseconds(100), duration <= .seconds(20) else {
            throw XcdError(.usage, "--duration \(DurationText.format(duration)) is outside 0.1s to 20s", next: "pass a duration like 1s or 2.5s")
        }
        var request = try targetRequest(target, gone: false, options, in: ctx)
        request.tree = options.tree
        request.duration = DurationText.seconds(duration)
        let call = ActionCall(path: RunnerProtocol.longPressPath, request: request, what: "long-press", target: target)
        return try await act(call, options, in: &ctx).report("long-pressed", target: target, detail: "for \(DurationText.format(duration))")
    }

    public func swipe(_ swipe: SwipeOptions, _ options: UIOptions, in ctx: inout WorktreeContext) async throws -> UIActionReport {
        let request = try swipeRequest(swipe, options, in: ctx)
        let target = swipe.on ?? "the screen"
        let done = try await act(ActionCall(path: RunnerProtocol.swipePath, request: request, what: "swipe", target: target), options, in: &ctx)
        let from = "\(ScreenRect.number(done.result.x ?? 0)),\(ScreenRect.number(done.result.y ?? 0))"
        let to = "\(ScreenRect.number(done.result.toX ?? 0)),\(ScreenRect.number(done.result.toY ?? 0))"
        guard let direction = request.direction else { return done.report("swiped", target: "from \(from) to \(to)") }
        // An element's line already says where the swipe began.
        return done.report("swiped \(direction.rawValue) on", target: target, detail: done.result.element == nil ? "from \(from) to \(to)" : "to \(to)")
    }

    static let swipeForms = "`xcd ui swipe up|down|left|right [--on <target>]`, or `xcd ui swipe --from x,y --to x,y`"

    func swipeRequest(_ swipe: SwipeOptions, _ options: UIOptions, in ctx: WorktreeContext) throws -> SwipeRequest {
        let scope = try self.scope(options, in: ctx)
        guard let name = swipe.direction else {
            guard swipe.on == nil, let from = swipe.from, let to = swipe.to else {
                throw XcdError(.usage, "a swipe needs a direction, or both --from and --to", next: "use " + Self.swipeForms)
            }
            return SwipeRequest(scope: scope, direction: nil, on: nil, from: try point(from, flag: "--from"), to: try point(to, flag: "--to"))
        }
        guard let direction = SwipeDirection(rawValue: name) else {
            throw XcdError(.usage, "'\(name)' is not a direction", next: "use one of: up, down, left, right")
        }
        guard swipe.from == nil, swipe.to == nil else {
            throw XcdError(.usage, "a direction and --from/--to can't be combined", next: "use " + Self.swipeForms)
        }
        let on = try swipe.on.map { try query($0, options) }
        if case .point? = on?.target {
            throw XcdError(.usage, "--on takes an element, not a point", next: "swipe between points with `xcd ui swipe --from x,y --to x,y`")
        }
        return SwipeRequest(scope: scope, direction: direction, on: on, from: nil, to: nil)
    }

    /// "x,y" (or "@x,y") in points.
    func point(_ text: String, flag: String) throws -> ScreenPoint {
        guard case .success(.point(let x, let y)) = TargetParser.parse(text.hasPrefix("@") ? text : "@" + text) else {
            throw XcdError(.usage, "\(flag) \(text) is not a point", next: "pass points as x,y, e.g. \(flag) 200,600")
        }
        return ScreenPoint(x: x, y: y)
    }
}
