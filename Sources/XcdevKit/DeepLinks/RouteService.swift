import Foundation

/// `xcd open`: lists the project's routes and delivers one to this worktree's app.
public struct RouteService: Sendable {
    public let apps: RunService

    /// A link that must start the app gets 60 looks, half a second apart, to do it.
    static let coldPolls = 60
    static let coldPollInterval: Duration = .milliseconds(500)

    public init(apps: RunService) { self.apps = apps }

    public func list(in ctx: WorktreeContext) -> RouteListReport {
        RouteListReport(config: ctx.config, worktree: ctx.state.name)
    }

    /// Opens a route or a URL. Parameters and flags are checked before anything touches the device.
    public func open(_ request: OpenRequest, _ options: OpenOptions, in ctx: inout WorktreeContext) async throws -> OpenReport {
        let route = try RouteResolver(config: ctx.config).resolve(request)
        let device = try apps.builds.provisioner.deviceName(options.device, config: ctx.config)
        let plan = try OpenPlan(route, options, onMac: ctx.config.allDevices[device]?.isMac == true, config: ctx.config)
        if options.dryRun { return plan.report(device: device, dryRun: true, worktree: ctx.state.name) }
        switch route.delivery {
        case .script:
            throw RouteErrors.scriptsNotYet(route)
        case .url(let url):
            return try await send(url, plan, in: &ctx)
        case .launch:
            return try await relaunch(plan, in: &ctx)
        }
    }

    /// An app after its route was delivered: how it got there, and what to watch.
    struct Delivered {
        let state: AppArrival
        let started: StartedApp
        let window: Duration
        /// Whether `started.appLog` holds this run's output.
        let captured: Bool
        /// False when the copy xcd started was gone before its link could be sent.
        var linkSent = true
    }

    func send(_ url: String, _ plan: OpenPlan, in ctx: inout WorktreeContext) async throws -> OpenReport {
        let app = try await apps.prepare(plan.requestedDevice, boot: true, in: &ctx)
        try RouteErrors.checkScheme(url, registeredBy: app.product)
        let running = try await app.host.runningPid(app.product)
        let delivered: Delivered
        if plan.cold, let host = app.host.launching(with: url) {
            delivered = try await startWithLink(PreparedApp(target: app.target, product: app.product, host: host), plan, in: &ctx)
        } else if plan.cold {
            delivered = try await startByLink(url, app, replacing: running, in: &ctx)
        } else if let pid = running, plan.preset == nil {
            delivered = try await sendToRunning(url, app, pid: pid, in: ctx)
        } else {
            let started = try await apps.begin(app, plan.launch, in: &ctx)
            let sent = try await sendIfAlive(url, to: started, app)
            delivered = Delivered(state: running == nil ? .started : .restarted, started: started, window: plan.launch.crashWindow,
                                  captured: true, linkSent: sent)
        }
        let report = plan.report(device: app.target.name, dryRun: false, worktree: ctx.state.name)
        return try await finish(report, plan, app, delivered)
    }

    func relaunch(_ plan: OpenPlan, in ctx: inout WorktreeContext) async throws -> OpenReport {
        let app = try await apps.prepare(plan.requestedDevice, boot: true, in: &ctx)
        let wasRunning = try await app.host.runningPid(app.product) != nil
        let started = try await apps.begin(app, plan.launch, in: &ctx)
        let delivered = Delivered(state: wasRunning ? .restarted : .started, started: started, window: plan.launch.crashWindow,
                                  captured: true)
        let report = plan.report(device: app.target.name, dryRun: false, worktree: ctx.state.name)
        return try await finish(report, plan, app, delivered)
    }

    /// Sends the link to the copy xcd just started, unless that copy is already gone: a link would start the app a
    /// second time, and its crash would be reported as one that followed the link. False when nothing was sent.
    func sendIfAlive(_ url: String, to started: StartedApp, _ app: PreparedApp) async throws -> Bool {
        guard started.crashedAtLaunch == nil, apps.watcher.probe.isRunning(started.pid) else { return false }
        do {
            try await app.host.open(url, in: app.product)
        } catch var error as XcdError {
            error.details.append("xcd had started the app (pid \(started.pid)) before this failed, and the link was not sent")
            throw error
        }
        return true
    }

    /// The link goes to the copy that is up. Its output is in the log of the launch that started it, if xcd did.
    func sendToRunning(_ url: String, _ app: PreparedApp, pid: Int32, in ctx: WorktreeContext) async throws -> Delivered {
        let sentAt = apps.builds.now()
        try await app.host.open(url, in: app.product)
        let launch = try AppStateStore.load(ctx.paths).lastLaunch
        let log = launch?.pid == pid && launch?.target == app.target.name ? launch?.appLog : nil
        return Delivered(state: .running, started: StartedApp(pid: pid, appLog: log ?? "", launchedAt: sentAt),
                         window: CrashWindows.running, captured: log != nil)
    }

    /// `--cold` where xcd can start the app with the link attached (a Mac): the running copy is replaced, the app's
    /// output is captured, and a preset's arguments apply.
    func startWithLink(_ app: PreparedApp, _ plan: OpenPlan, in ctx: inout WorktreeContext) async throws -> Delivered {
        let started = try await apps.begin(app, plan.launch, in: &ctx)
        return Delivered(state: .startedByLink, started: started, window: plan.launch.crashWindow, captured: true)
    }

    /// `--cold` on a simulator: the app is stopped, and the system starts it because of the link.
    func startByLink(_ url: String, _ app: PreparedApp, replacing old: Int32?, in ctx: inout WorktreeContext) async throws -> Delivered {
        if old != nil { _ = try await app.host.terminate(app.product) }
        let sentAt = apps.builds.now()
        // A report an earlier crash left moments ago must not be taken for this start's.
        let earlier = simulatorCrash(of: app, since: sentAt)?.path
        try await app.host.open(url, in: app.product)
        guard let outcome = try await linkStarted(app, since: sentAt, otherThan: old, earlierCrash: earlier) else {
            throw RouteErrors.notStarted(url, app.product)
        }
        var started = StartedApp(pid: outcome.pid, appLog: try Self.uncapturedLog(ctx.paths, at: sentAt), launchedAt: sentAt)
        started.crashedAtLaunch = outcome.crash.map { .exited(after: 0, crash: $0) }
        try await apps.settle(started, app, in: &ctx)
        return Delivered(state: .startedByLink, started: started, window: CrashWindows.started, captured: false)
    }

    /// What a link that had to start the app did: the pid of the process it started, and that process's crash report
    /// when it died before it was ever seen.
    struct ColdStart {
        let pid: Int32
        var crash: CrashReport?
    }

    /// Looks for the process the link started. The stopped copy can still be listed for a moment, so it is not taken
    /// for the new one. An app that crashes on the link can be gone before the first look: its crash report is then
    /// the sign that it started, when the report is of this simulator's copy. Nil when neither shows up.
    func linkStarted(_ app: PreparedApp, since sentAt: Date, otherThan old: Int32?, earlierCrash: String?) async throws -> ColdStart? {
        for _ in 0..<Self.coldPolls {
            if let pid = try await app.host.runningPid(app.product), pid != old { return ColdStart(pid: pid) }
            if let crash = simulatorCrash(of: app, since: sentAt), crash.path != earlierCrash {
                return ColdStart(pid: crash.pid, crash: crash)
            }
            try await apps.sleep(Self.coldPollInterval)
        }
        return nil
    }

    /// The newest crash report of the app's process on this simulator. The reports folder is shared by every simulator,
    /// so another worktree's copy of the app crashing is not this link's start. None for an app without a simulator.
    func simulatorCrash(of app: PreparedApp, since date: Date) -> CrashReport? {
        guard let udid = app.target.device?.udid else { return nil }
        return apps.watcher.locator.find(processName: app.product.executableName, since: date, from: .simulator(udid))
    }

    /// The system started this run, so nothing captured what it printed. Its app log says so, which keeps
    /// `xcd logs --app` from showing an older run's output as if it were this one's.
    static func uncapturedLog(_ paths: WorktreePaths, at date: Date) throws -> String {
        let log = paths.newArtifact(in: paths.logs, kind: "app", ext: "log", now: date)
        try "xcd: this run was started by a link (`xcd open --cold`), so what the app printed was not captured. Its log messages are in the unified log: `xcd logs`.\n"
            .write(toFile: log, atomically: true, encoding: .utf8)
        return log
    }

    /// Watches the app for the delivery's window and completes the report. A process that ends is a crash.
    func finish(_ base: OpenReport, _ plan: OpenPlan, _ app: PreparedApp, _ delivered: Delivered) async throws -> OpenReport {
        var report = base
        report.deviceSummary = app.target.summary
        let started = delivered.started
        report.app = OpenReport.App(state: delivered.state, pid: started.pid, bundleId: app.product.bundleId,
                                    log: delivered.captured ? started.appLog : nil)
        if plan.route.delivery.kind == .url { report.linkSent = delivered.linkSent }
        if let target = plan.route.expect {
            report.check = OpenReport.Check(target: target, outcome: .skipped, seconds: nil,
                                            reason: "the arrival check is not in this version; use `xcd ui wait \(Shell.quote(target))`")
        }
        if case .exited(let after, let crash) = try await watch(delivered, app) {
            report.exitedAfter = after
            report.crash = crash
            report.appOutput = delivered.captured ? RunService.tail(of: started.appLog, lines: 10) : nil
        }
        return report
    }

    /// What became of the app in the delivery's window. An app that died as it started is not watched: its end is known.
    func watch(_ delivered: Delivered, _ app: PreparedApp) async throws -> LaunchOutcome {
        let started = delivered.started
        if let crashed = started.crashedAtLaunch { return crashed }
        if delivered.linkSent {
            apps.builds.progress("delivered to \(app.product.bundleId) (pid \(started.pid)); watching \(DurationText.format(delivered.window)) for a crash")
        }
        return try await apps.watcher.watch(pid: started.pid, processName: app.product.executableName, window: delivered.window,
                                            launchedAt: started.launchedAt)
    }
}
