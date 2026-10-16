import Foundation

/// `xcd open`: lists the project's routes and delivers one to this worktree's app.
public struct RouteService: Sendable {
    public let apps: RunService
    /// Looks for a route's `expect` once the route was delivered.
    public let arrival: any ArrivalLooking
    /// Passed to a route's script as XCD_OUTPUT.
    public let output: OutputFormat

    /// A link that must start the app gets 60 looks, half a second apart, to do it.
    static let coldPolls = 60
    static let coldPollInterval: Duration = .milliseconds(500)

    public init(apps: RunService, arrival: any ArrivalLooking, output: OutputFormat = .text) {
        self.apps = apps
        self.arrival = arrival
        self.output = output
    }

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
            return try await runScript(plan, on: device, in: &ctx)
        case .url(let url):
            return try await send(url, plan, in: &ctx)
        case .launch:
            return try await relaunch(plan, in: &ctx)
        }
    }

    /// A script route: the simulator is booted, and the project's script does the rest. No build is needed, and xcd
    /// does not start, stop, or watch the app. The route's `expect` is looked for once the
    /// script has exited 0.
    func runScript(_ plan: OpenPlan, on device: String, in ctx: inout WorktreeContext) async throws -> OpenReport {
        var target = BuildTarget(name: device, destination: .macOS, device: nil)
        if ctx.config.allDevices[device]?.isMac != true {
            let clone = try await apps.builds.provisioner.boot(device, in: &ctx).device
            target = BuildTarget(name: device, destination: .simulator(udid: clone.udid), device: clone)
        }
        let script = RouteScript(runner: apps.builds.runner, progress: apps.builds.progress, now: apps.builds.now)
        var report = plan.report(device: device, dryRun: false, worktree: ctx.state.name)
        report.scriptLog = try await script.run(plan.route, context: .build(ctx: ctx, device: device, output: output), logs: ctx.paths)
        report.deviceSummary = target.summary
        // The script may have built the app, so what xcd knows of it is read once the script is done.
        report.app = OpenReport.App(state: .untouched, pid: nil, bundleId: ContextInfo.build(ctx: ctx, device: device).bundleId, log: nil)
        report.arrived(await arrive(arrivalPlan(plan.route, on: device, in: ctx), after: plan.route, in: ctx))
        return report
    }

    func send(_ url: String, _ plan: OpenPlan, in ctx: inout WorktreeContext) async throws -> OpenReport {
        let app = try await apps.prepare(plan.requestedDevice, boot: true, in: &ctx)
        try RouteErrors.checkScheme(url, registeredBy: app.product)
        try RouteErrors.checkPlatform(url, for: app.product)
        let running = try await app.host.runningPid(app.product)
        var delivered: Delivered
        if plan.cold, let host = app.host.launching(with: url) {
            delivered = try await startWithLink(PreparedApp(target: app.target, product: app.product, host: host), plan, in: &ctx)
        } else if plan.cold {
            delivered = try await startByLink(url, app, replacing: running, in: &ctx)
        } else if let pid = running, plan.preset == nil {
            // What the route expects may be on screen already. Seeing it after the link would then prove nothing.
            let seen = await alreadyThere(arrivalPlan(plan.route, on: app.target.name, in: ctx), in: &ctx)
            delivered = try await sendToRunning(url, app, pid: pid, in: ctx)
            delivered.alreadyThere = seen
        } else {
            let started = try await apps.begin(app, plan.launch, in: &ctx)
            let sent = try await sendIfAlive(url, to: started, app)
            delivered = Delivered(state: running == nil ? .started : .restarted, started: started, window: plan.launch.crashWindow,
                                  captured: true, linkSent: sent)
        }
        return try await finish(delivered, plan, app, in: ctx)
    }

    func relaunch(_ plan: OpenPlan, in ctx: inout WorktreeContext) async throws -> OpenReport {
        let app = try await apps.prepare(plan.requestedDevice, boot: true, in: &ctx)
        let wasRunning = try await app.host.runningPid(app.product) != nil
        let started = try await apps.begin(app, plan.launch, in: &ctx)
        let delivered = Delivered(state: wasRunning ? .restarted : .started, started: started, window: plan.launch.crashWindow,
                                  captured: true)
        return try await finish(delivered, plan, app, in: ctx)
    }

    /// Watches the app for the delivery's window, looks for the route's `expect` beside the watch, and completes
    /// the report. The watch always runs for its whole window, and the command returns when both are done. A process
    /// that ends before then is a crash, whatever the look saw. The look can go on
    /// long after the window, so when one was made the process is asked for once more at the end.
    func finish(_ delivered: Delivered, _ plan: OpenPlan, _ app: PreparedApp, in ctx: WorktreeContext) async throws -> OpenReport {
        var report = plan.report(device: app.target.name, dryRun: false, worktree: ctx.state.name)
        report.deviceSummary = app.target.summary
        let started = delivered.started
        report.app = OpenReport.App(state: delivered.state, pid: started.pid, bundleId: app.product.bundleId,
                                    log: delivered.captured ? started.appLog : nil)
        if report.kind == .url { report.linkSent = delivered.linkSent }
        let check = checkPlan(delivered, plan, app, in: ctx)
        let watchedFrom = apps.builds.now()
        async let watching = watch(delivered, app)
        async let arriving = arrive(check, after: plan.route, in: ctx)
        let (watched, arrived) = try await (watching, arriving)
        report.arrived(arrived)
        var outcome = watched
        if case .look = check, watched == .running { outcome = try await outcomeAfterLook(of: started, app, watchedFrom: watchedFrom) }
        if case .exited(let after, let crash) = outcome {
            report.exitedAfter = after
            report.crash = crash
            report.appOutput = delivered.captured ? RunService.tail(of: started.appLog, lines: 10) : nil
        }
        report.note = Self.note(for: app, uncheckedWebLink: check == .none && delivered.linkSent && !report.appEnded && plan.route.isWebLink)
        return report
    }

    /// What the result notes. A Mac app shares its data with every worktree's build of it. On a simulator the system
    /// decides where an https link goes, and with no check nothing looked: that is
    /// said of a link that went out to an app that is still there, since when the app ended, the crash is the result.
    static func note(for app: PreparedApp, uncheckedWebLink: Bool) -> String? {
        guard app.target.device != nil else { return RunReport.sharedData(of: app.product.bundleId) }
        return uncheckedWebLink ? RouteErrors.uncheckedWebLink : nil
    }

    /// The check for this delivery: none for a link that never went out or an app that crashed as it started, since
    /// the crash is then the result and a look would only wait for an app that is gone. Nothing to wait for when the
    /// element was on screen before the link went to a copy that was already up. When the look before could not
    /// tell, the look after is still made, and a find proves nothing.
    func checkPlan(_ delivered: Delivered, _ plan: OpenPlan, _ app: PreparedApp, in ctx: WorktreeContext) -> ArrivalPlan {
        guard delivered.linkSent, delivered.started.crashedAtLaunch == nil else { return .none }
        let planned = arrivalPlan(plan.route, on: app.target.name, in: ctx)
        guard case .look(let target, let device, _) = planned else { return planned }
        switch delivered.alreadyThere {
        case .seen: return .inconclusive(target: target)
        case .couldNotTell(let why): return .look(target: target, device: device, unsure: why)
        case .notSeen: return planned
        }
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

    /// What became of an app that the watch left running, once the look for the route's `expect` is done too. The
    /// look can go on long after the watch's window, and xcd still has the pid: a process that ended in that time
    /// is a crash, not an element that did not appear. The process is asked for once, and its
    /// crash report is looked for only when it is gone. xcd cannot tell when in that time the process ended, so
    /// `after` is how long xcd had been watching when it saw that the process was gone.
    func outcomeAfterLook(of started: StartedApp, _ app: PreparedApp, watchedFrom: Date) async throws -> LaunchOutcome {
        guard !apps.watcher.probe.isRunning(started.pid) else { return .running }
        let after = apps.builds.now().timeIntervalSince(watchedFrom)
        let crash = try await apps.watcher.report(processName: app.product.executableName, pid: started.pid, since: started.launchedAt)
        return .exited(after: after, crash: crash)
    }
}
