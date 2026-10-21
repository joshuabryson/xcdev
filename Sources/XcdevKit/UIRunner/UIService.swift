import AppKit
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
    /// For an action: print the tree as it is afterwards.
    public var tree = false

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
    /// How long the runner may take beyond the element timeout: to snapshot, act, and reply.
    var slack: Duration = .seconds(30)
}

/// `xcd ui tree`, `tap`, `wait`, and `stop`. The other actions are in UIActions.swift.
public struct UIService: Sendable {
    public let supervisor: RunnerSupervisor
    public let client: RunnerClient
    /// Finds the crash report of an app that an action ended.
    public let crashes: CrashReportLocator
    let now: @Sendable () -> Date
    /// The Accessibility API for a Mac device, made fresh for each command: the real one holds CF objects.
    let accessibility: @Sendable () -> any AccessibilityAPI
    /// The app macOS attributes xcd's grants to.
    let hostApp: @Sendable () -> String
    /// The pids of the running apps with a bundle id, for `--bundle` on a Mac.
    let running: @Sendable (String) -> [Int32]
    /// Whether the Mac's screen is locked, which makes every window read meaningless.
    let screenLocked: @Sendable () -> Bool

    public init(supervisor: RunnerSupervisor, client: RunnerClient, crashes: CrashReportLocator = CrashReportLocator(),
                now: @escaping @Sendable () -> Date = { Date() },
                accessibility: @escaping @Sendable () -> any AccessibilityAPI = { SystemAccessibility() },
                hostApp: @escaping @Sendable () -> String = { MacHostApp.live() },
                running: @escaping @Sendable (String) -> [Int32] = { NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier) },
                screenLocked: @escaping @Sendable () -> Bool = { MacScreenLock.isLocked() }) {
        self.supervisor = supervisor
        self.client = client
        self.crashes = crashes
        self.now = now
        self.accessibility = accessibility
        self.hostApp = hostApp
        self.running = running
        self.screenLocked = screenLocked
    }

    public func tree(all: Bool, _ options: UIOptions, in ctx: inout WorktreeContext) async throws -> UITreeReport {
        let request = TreeRequest(bundleId: try bundleId(options, in: ctx), system: options.system, all: all)
        let (session, result) = try await send(RunnerExchange(path: RunnerProtocol.treePath, request: request, what: "read", resend: true),
                                               as: TreeResult.self, options, in: &ctx)
        let tree = try result.mapError { UIRunnerErrors.error($0, target: "the screen", timeout: options.effectiveTimeout) }.get()
        return UITreeReport(device: session.device, udid: session.udid, restarted: session.restarted, tree: tree, worktree: ctx.state.name)
    }

    public func tap(_ target: String, _ options: UIOptions, in ctx: inout WorktreeContext) async throws -> UIActionReport {
        var request = try targetRequest(target, gone: false, options, in: ctx)
        request.tree = options.tree
        let call = ActionCall(path: RunnerProtocol.tapPath, request: request, what: "tap", target: target)
        return try await act(call, options, in: &ctx).report("tapped", target: target)
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
        if ctx.config.allDevices[name]?.isMac == true {
            let file = MacRefStore.file(ctx.paths, device: name)
            let had = Disk.exists(file)
            MacRefStore.forget(file)
            return UIStopReport(device: name, stopped: [(had ? "forgot the refs of \(name)" : "no refs to forget for \(name)") + "; there is no runner to stop on a Mac"]
                                + (rebuild ? ["--rebuild does nothing on a Mac"] : []), rebuild: false, worktree: ctx.state.name)
        }
        let stopped = try await supervisor.stop(device: name, in: ctx)
        if rebuild { try await supervisor.builder.discard(xcode: try await supervisor.provisioner.ensureXcode(&ctx)) }
        return UIStopReport(device: name, stopped: stopped, rebuild: rebuild, worktree: ctx.state.name)
    }

    func targetRequest(_ target: String, gone: Bool, _ options: UIOptions, in ctx: WorktreeContext) throws -> TargetRequest {
        let query = try self.query(target, options)
        return TargetRequest(bundleId: try bundleId(options, in: ctx), system: options.system, target: query.target, role: query.role,
                             index: query.index, timeout: DurationText.seconds(options.effectiveTimeout), gone: gone)
    }

    /// The element a target string and `--role`/`--index` name; a `usage` error when either can't be read.
    func query(_ target: String, _ options: UIOptions) throws -> ElementQuery {
        guard case .success(let spec) = TargetParser.parse(target) else {
            throw XcdError(.usage, "'\(target)' is not a target", next: "use " + TargetParser.forms)
        }
        if let role = options.role, !ElementRole.all.contains(role) {
            throw XcdError(.usage, "'\(role)' is not a role", next: "use one of: " + ElementRole.all.joined(separator: ", "))
        }
        return ElementQuery(target: spec, role: options.role, index: options.index)
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
        // The runner keeps looking for `timeout`; give the HTTP request that long plus time to snapshot, act, and reply.
        let httpTimeout = options.effectiveTimeout + exchange.slack
        func call(_ session: RunnerSession) async throws -> Result<Payload, RunnerFailure> {
            try await client.call(exchange.path, exchange.request, to: session.endpoint, timeout: httpTimeout)
        }
        if let mac = try await macSession(options, in: ctx) {
            return (mac.session, try mac.perform(exchange.path, exchange.request))
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

/// A Mac device runs the engine in-process over the Accessibility API instead of a runner.
extension UIService {
    /// A Mac device's session, or nil for a simulator device. `--system` is refused, then a locked screen (whose
    /// windows read as garbage, granted or not), then a missing grant; only then is the app's process looked for.
    func macSession(_ options: UIOptions, screenRecording: Bool = false, in ctx: WorktreeContext) async throws -> MacUISession? {
        let name = try supervisor.provisioner.deviceName(options.device, config: ctx.config)
        guard ctx.config.allDevices[name]?.isMac == true else { return nil }
        if options.system {
            throw XcdError(.platformUnsupported, "a Mac has no Home Screen to drive: --system is for Springboard, and the desktop is the person's",
                           next: "drop --system; the app's own windows, sheets, and menus are in `xcd ui tree`")
        }
        if screenLocked() {
            throw XcdError(.runnerFailed, "the Mac's screen is locked, so the app's windows cannot be read",
                           next: "ask the user to unlock the Mac, then run the command again")
        }
        let api = accessibility()
        try MacPermissions.read(api: api, hostApp: hostApp()).require(screenRecording: screenRecording)
        let pid = try await macPid(options, device: name, in: ctx)
        return MacUISession(device: name, pid: pid, api: api, refFile: MacRefStore.file(ctx.paths, device: name))
    }

    /// `--bundle` names a running app; otherwise the build record's product must be running from this worktree's path.
    func macPid(_ options: UIOptions, device: String, in ctx: WorktreeContext) async throws -> Int32 {
        guard let bundle = options.bundle else {
            return try await MacAppLookup.runningPid(device: device, runner: supervisor.provisioner.runner, in: ctx)
        }
        let running = self.running(bundle)
        guard running.count == 1, let pid = running.first else {
            throw XcdError(.usage, running.isEmpty ? "no running app has the bundle id \(bundle)" : "\(running.count) running apps have the bundle id \(bundle)",
                           next: running.isEmpty ? "start it first, or drop --bundle to drive this worktree's build" : "quit the others, or drop --bundle")
        }
        return pid
    }

    /// Whether `device` (or the default device) is a Mac; false for a name .xcdev.yml does not have.
    func isMac(_ device: String?, in ctx: WorktreeContext) -> Bool {
        guard let name = try? supervisor.provisioner.deviceName(device, config: ctx.config) else { return false }
        return ctx.config.allDevices[name]?.isMac == true
    }
}
