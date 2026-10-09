import Foundation

/// How `xcd open` gets a link to the app: to the copy that is up, to one xcd just started, or by letting the link
/// start the app.
extension RouteService {
    /// An app after its route was delivered: how it got there, and what to watch.
    struct Delivered: Sendable {
        let state: AppArrival
        let started: StartedApp
        let window: Duration
        /// Whether `started.appLog` holds this run's output.
        let captured: Bool
        /// False when the copy xcd started was gone before its link could be sent.
        var linkSent = true
        /// The route's `expect` was on screen before the link went to a copy that was already up.
        var alreadyThere = false
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
}
