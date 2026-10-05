import Foundation

/// The options every `xcd ui` driving command takes.
public struct UIOptions: Sendable {
    public var device: String?
    /// The app to drive; default: the app of the last build for the device.
    public var bundle: String?
    /// Drive Springboard (the Home Screen) instead of an app.
    public var system: Bool
    public var role: String?
    public var index: Int?
    /// How long to keep looking for an element. The runner clamps it to 0...120 s, and so does xcd.
    public var timeout: Duration

    public init(device: String?, bundle: String?, system: Bool, role: String?, index: Int?, timeout: Duration) {
        self.device = device
        self.bundle = bundle
        self.system = system
        self.role = role
        self.index = index
        self.timeout = timeout
    }

    /// The timeout as the runner will apply it.
    var effectiveTimeout: Duration { min(max(timeout, .zero), .seconds(120)) }
}

/// One request to the runner: where it goes, what it says, and whether a lost answer allows sending it again.
struct RunnerExchange<Request: Encodable> {
    let path: String
    let request: Request
    /// "tap", "wait", or "read", for the error that says what may have happened.
    let what: String
    /// A read can be sent again after a restart; an action may already have happened.
    let resend: Bool
}

/// `xcd ui tree`, `tap`, `wait`, and `stop`.
public struct UIService: Sendable {
    public let supervisor: RunnerSupervisor
    public let client: RunnerClient

    public init(supervisor: RunnerSupervisor, client: RunnerClient) {
        self.supervisor = supervisor
        self.client = client
    }

    public func tree(all: Bool, _ options: UIOptions, in ctx: inout WorktreeContext) async throws -> UITreeReport {
        let request = TreeRequest(bundleId: try bundleId(options, in: ctx), system: options.system, all: all)
        let (session, result) = try await send(RunnerExchange(path: RunnerProtocol.treePath, request: request, what: "read", resend: true),
                                               as: TreeResult.self, options, in: &ctx)
        let tree = try result.mapError { UIRunnerErrors.error($0, target: "the screen", timeout: options.effectiveTimeout) }.get()
        return UITreeReport(device: session.device, udid: session.udid, restarted: session.restarted, tree: tree, worktree: ctx.state.name)
    }

    public func tap(_ target: String, _ options: UIOptions, in ctx: inout WorktreeContext) async throws -> UIActionReport {
        let request = try targetRequest(target, gone: false, options, in: ctx)
        let (session, result) = try await send(RunnerExchange(path: RunnerProtocol.tapPath, request: request, what: "tap", resend: false),
                                               as: ActionResult.self, options, in: &ctx)
        let action = try result.mapError { UIRunnerErrors.error($0, target: target, timeout: options.effectiveTimeout) }.get()
        return UIActionReport(action: "tapped", target: target, element: action.element, x: action.x, y: action.y, ms: action.ms,
                              restarted: session.restarted, device: session.device, udid: session.udid, worktree: ctx.state.name)
    }

    public func wait(_ target: String, gone: Bool, _ options: UIOptions, in ctx: inout WorktreeContext) async throws -> UIWaitReport {
        let request = try targetRequest(target, gone: gone, options, in: ctx)
        if case .point = request.target {
            // The runner would refuse this too; say so before a runner is built or started.
            throw XcdError(.usage, "a point can't be waited for: '\(target)' names a place on screen, not an element",
                           next: "wait for an element with `id:<identifier>`, `label:<text>`, or `label~<part>`")
        }
        let (session, result) = try await send(RunnerExchange(path: RunnerProtocol.waitPath, request: request, what: "wait", resend: true),
                                               as: ActionResult.self, options, in: &ctx)
        let action = try result.mapError { UIRunnerErrors.error($0, target: target, timeout: options.effectiveTimeout) }.get()
        return UIWaitReport(target: target, gone: gone, element: action.element, ms: action.ms, restarted: session.restarted,
                            device: session.device, udid: session.udid, worktree: ctx.state.name)
    }

    /// Stops the device's runner. With `rebuild`, also discards the cached runner build for this Xcode.
    public func stop(device: String?, rebuild: Bool, in ctx: inout WorktreeContext) async throws -> UIStopReport {
        let name = try supervisor.provisioner.deviceName(device, config: ctx.config)
        let stopped = try await supervisor.stop(device: name, in: ctx)
        if rebuild { try await supervisor.builder.discard(xcode: try await supervisor.provisioner.ensureXcode(&ctx)) }
        return UIStopReport(device: name, stopped: stopped, rebuild: rebuild, worktree: ctx.state.name)
    }

    func targetRequest(_ target: String, gone: Bool, _ options: UIOptions, in ctx: WorktreeContext) throws -> TargetRequest {
        guard case .success(let spec) = TargetParser.parse(target) else {
            throw XcdError(.usage, "'\(target)' is not a target", next: "use " + TargetParser.forms)
        }
        if let role = options.role, !ElementRole.all.contains(role) {
            throw XcdError(.usage, "'\(role)' is not a role", next: "use one of: " + ElementRole.all.joined(separator: ", "))
        }
        return TargetRequest(bundleId: try bundleId(options, in: ctx), system: options.system, target: spec, role: options.role,
                             index: options.index, timeout: DurationText.seconds(options.effectiveTimeout), gone: gone)
    }

    /// `--system` means no app; else `--bundle`; else the app of the last build for the device.
    func bundleId(_ options: UIOptions, in ctx: WorktreeContext) throws -> String? {
        if options.system { return nil }
        if let bundle = options.bundle { return bundle }
        let name = try supervisor.provisioner.deviceName(options.device, config: ctx.config)
        guard let id = try AppStateStore.load(ctx.paths).builds[name]?.product?.bundleId else {
            throw XcdError(.appNotBuilt, "no app has been built for \(name) in this worktree, so xcd doesn't know which app to drive",
                           next: "pass --bundle <id>, use --system for the Home Screen, or build first with `xcd build --device \(name)`")
        }
        return id
    }

    /// Sends one request. If the runner doesn't answer, it is restarted once; a read is then sent again, an action is
    /// not, because it may already have happened. A live runner's refusal (an `XcdError`) is not a restart.
    func send<Request: Encodable, Payload: Codable>(_ exchange: RunnerExchange<Request>, as payload: Payload.Type, _ options: UIOptions,
                                                    in ctx: inout WorktreeContext) async throws -> (RunnerSession, Result<Payload, RunnerFailure>) {
        // The runner keeps looking for `timeout`; give the HTTP request that long plus time to snapshot and reply.
        let httpTimeout = options.effectiveTimeout + .seconds(30)
        func call(_ session: RunnerSession) async throws -> Result<Payload, RunnerFailure> {
            try await client.call(exchange.path, exchange.request, to: session.endpoint, timeout: httpTimeout)
        }
        let session = try await supervisor.session(device: options.device, in: &ctx)
        do {
            return (session, try await call(session))
        } catch is RunnerUnreachable {
            let fresh = try await supervisor.session(device: options.device, in: &ctx, restart: true)
            guard exchange.resend else {
                throw XcdError(.runnerFailed, "the UI runner stopped answering during the \(exchange.what), so it may or may not have happened",
                               next: "check with `xcd ui tree`; the runner has been restarted")
            }
            do {
                return (fresh, try await call(fresh))
            } catch is RunnerUnreachable {
                throw XcdError(.runnerFailed, "the UI runner stopped answering again right after a restart",
                               next: "run `xcd ui stop`, then `xcd doctor`")
            }
        }
    }
}
