import Foundation

public struct LaunchOptions: Sendable {
    public var preset: String?
    public var arguments: [String]
    public var environment: [String: String]
    public var crashWindow: Duration
    /// Mac apps: start visible and in front.
    public var show: Bool

    public init(preset: String? = nil, arguments: [String] = [], environment: [String: String] = [:],
                crashWindow: Duration = .seconds(5), show: Bool = false) {
        self.show = show
        self.preset = preset
        self.arguments = arguments
        self.environment = environment
        self.crashWindow = crashWindow
    }

    /// The preset's args followed by these args; the preset's env overridden by these env vars.
    public func resolved(config: XcdevConfig) throws -> (arguments: [String], environment: [String: String]) {
        guard let name = preset else { return (arguments, environment) }
        let presets = config.presets ?? [:]
        guard let found = presets[name] else {
            throw XcdError(.usage, "no preset named '\(name)' in .xcdev.yml",
                           next: presets.isEmpty ? "add one under `presets:` in .xcdev.yml"
                                                 : "use one of: \(presets.keys.sorted().joined(separator: ", "))")
        }
        return ((found.args ?? []) + arguments, (found.env ?? [:]).merging(environment, uniquingKeysWith: { $1 }))
    }

    /// The launch with the preset applied, or `usage` for a preset `.xcdev.yml` does not define.
    func plan(config: XcdevConfig) throws -> LaunchPlan {
        let (arguments, environment) = try resolved(config: config)
        return LaunchPlan(arguments: arguments, environment: environment, crashWindow: crashWindow)
    }

    /// `--env KEY=VALUE` values.
    public static func parseEnvironment(_ pairs: [String]) throws -> [String: String] {
        var environment: [String: String] = [:]
        for pair in pairs {
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                throw XcdError(.usage, "--env \(pair) is not KEY=VALUE", next: "pass --env NAME=value")
            }
            environment[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        return environment
    }
}

/// A launch with its preset applied.
struct LaunchPlan: Sendable, Equatable {
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var crashWindow: Duration = .seconds(5)
}

/// The latest build's app for one target, and the host it runs on.
struct PreparedApp: Sendable {
    let target: BuildTarget
    /// What runs: the build's product, or under `isolation: suffix` this worktree's copy of it.
    let product: AppProduct
    let host: any AppHost
    /// The product the build recorded, which a copy is made from; the same as `product` when there is no copy.
    let built: AppProduct

    init(target: BuildTarget, product: AppProduct, host: any AppHost, built: AppProduct? = nil) {
        self.target = target
        self.product = product
        self.host = host
        self.built = built ?? product
    }

    /// Where this app's process runs, and so where its crash reports come from.
    var origin: CrashOrigin { target.device.map { .simulator($0.udid) } ?? .mac }
}

/// An app that has just been started: what recording the launch, watching it, and reporting it need.
struct StartedApp: Sendable {
    let pid: Int32
    let appLog: String
    /// Taken before the app started: crash reports are matched to launches written at or after this time.
    let launchedAt: Date
    /// Set when the app died before its process was ever seen. Its crash is then already known.
    var crashedAtLaunch: LaunchOutcome?
}

public struct RunService: Sendable {
    public let builds: BuildService
    public let watcher: CrashWatcher
    /// A Mac device's data isolation: which copy a launch starts, and when another worktree's copy blocks it.
    public let isolation: MacIsolationService
    let sleep: @Sendable (Duration) async throws -> Void

    public init(builds: BuildService, watcher: CrashWatcher, isolation: MacIsolationService? = nil,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.builds = builds
        self.watcher = watcher
        self.isolation = isolation ?? MacIsolationService(runner: builds.runner)
        self.sleep = sleep
    }

    /// Build (unless `noBuild`), boot, install, launch, and watch for a crash.
    public func run(_ build: BuildOptions, noBuild: Bool, launch: LaunchOptions,
                    in ctx: inout WorktreeContext) async throws -> RunReport {
        let plan = try launch.plan(config: ctx.config)
        try requireMacForShow(build.device, launch.show, in: ctx)
        var buildReport: BuildReport?
        if !noBuild {
            let report = try await builds.buildNotingSetup(build, in: &ctx)
            guard report.succeeded else { return RunReport(buildFailed: report, worktree: ctx.state.name) }
            buildReport = report
        }
        let app = try await prepare(build.device, boot: true, show: launch.show, in: &ctx)
        try await app.host.install(app.product)
        return try await start(app, plan, build: buildReport, in: &ctx)
    }

    /// Launch the already-installed build (booting the clone if needed) and watch for a crash.
    public func launch(device: String?, options: LaunchOptions, in ctx: inout WorktreeContext) async throws -> RunReport {
        let plan = try options.plan(config: ctx.config)
        try requireMacForShow(device, options.show, in: ctx)
        let app = try await prepare(device, boot: true, show: options.show, in: &ctx)
        return try await start(app, plan, build: nil, in: &ctx)
    }

    public func install(device: String?, in ctx: inout WorktreeContext) async throws -> AppActionReport {
        let app = try await prepare(device, boot: true, in: &ctx)
        guard app.target.device != nil else {
            return AppActionReport(action: "nothing to install", bundleId: app.product.bundleId, target: app.target.name,
                                   note: "macOS apps run from this worktree (its DerivedData, or .xcdev/mac under isolation: suffix)",
                                   worktree: ctx.state.name)
        }
        try await app.host.install(app.product)
        return AppActionReport(action: "installed", bundleId: app.product.bundleId, target: app.target.name, note: nil,
                               worktree: ctx.state.name)
    }

    public func uninstall(device: String?, in ctx: inout WorktreeContext) async throws -> AppActionReport {
        let app = try await prepare(device, boot: true, in: &ctx)
        guard app.target.device != nil else {
            return AppActionReport(action: "nothing to uninstall", bundleId: app.product.bundleId, target: app.target.name,
                                   note: "macOS apps run from this worktree (its DerivedData, or .xcdev/mac under isolation: suffix)",
                                   worktree: ctx.state.name)
        }
        try await app.host.uninstall(app.product)
        return AppActionReport(action: "uninstalled", bundleId: app.product.bundleId, target: app.target.name, note: nil,
                               worktree: ctx.state.name)
    }

    public func terminate(device: String?, in ctx: inout WorktreeContext) async throws -> AppActionReport {
        let app = try await prepare(device, boot: false, in: &ctx)
        let stopped = try await app.host.terminate(app.product)
        return AppActionReport(action: stopped ? "terminated" : "not running", bundleId: app.product.bundleId,
                               target: app.target.name, note: nil, worktree: ctx.state.name)
    }

    /// The latest build's app for this target as every command sees it: under `isolation: suffix`, this worktree's
    /// copy of the Mac app, whether or not a launch has made it yet. `app_not_built` names the
    /// build to run.
    public static func product(for target: String, requested: String?, in ctx: WorktreeContext) throws -> AppProduct {
        try MacIsolationService.product(recordedProduct(for: target, requested: requested, in: ctx), device: target, in: ctx)
    }

    /// `--show` is for a Mac app: refused before any build or boot, with the device named as `prepare` names it.
    func requireMacForShow(_ device: String?, _ show: Bool, in ctx: WorktreeContext) throws {
        guard show else { return }
        let container = try ProjectContainer.resolve(config: ctx.config, worktreeRoot: ctx.location.worktreeRoot)
        let name = try builds.provisioner.targetName(device, container: container, config: ctx.config)
        guard ctx.config.allDevices[name]?.isMac == true else {
            throw XcdError(.usage, "--show is for a Mac app", next: "a simulator is shown with `xcd sim open`")
        }
    }

    /// The latest build's app for `device` and its host, cloning the simulator on first use. A Mac app's product is the
    /// device's derived identity, for every `boot`: under `isolation: suffix`, this worktree's copy, which only `begin`
    /// makes, once the running copy is stopped.
    func prepare(_ device: String?, boot: Bool, show: Bool = false,
                 in ctx: inout WorktreeContext) async throws -> PreparedApp {
        let container = try ProjectContainer.resolve(config: ctx.config, worktreeRoot: ctx.location.worktreeRoot)
        let name = try builds.provisioner.targetName(device, container: container, config: ctx.config)
        let built = try Self.recordedProduct(for: name, requested: device, in: ctx)
        let target = try await builds.provisioner.buildTarget(device, container: container, in: &ctx)
        guard let clone = target.device else {
            let host = MacAppHost(runner: builds.runner, sleep: sleep).showing(show)
            let product = MacIsolationService.product(built, device: name, in: ctx)
            return PreparedApp(target: target, product: product, host: host, built: built)
        }
        if boot { _ = try await builds.provisioner.boot(target.name, in: &ctx) }
        let host = SimulatorAppHost(simctl: builds.provisioner.simctl(for: ctx), udid: clone.udid)
        return PreparedApp(target: target, product: built, host: host)
    }

    private func start(_ app: PreparedApp, _ plan: LaunchPlan, build: BuildReport?,
                       in ctx: inout WorktreeContext) async throws -> RunReport {
        let started = try await begin(app, plan, in: &ctx)
        let outcome = try await outcome(of: started, app.product, window: plan.crashWindow)
        return Self.report(outcome, started, app, RunFacts(build: build, crashWindow: plan.crashWindow, ctx: ctx))
    }

    /// Starts the app, replacing a running copy, with its output going to a new log. Then records the launch and
    /// runs the post-launch hook (`settle`). On a Mac, the isolation's launch step comes once this worktree's running
    /// copy is stopped and its refs are forgotten: under `suffix` the copy is made or refreshed, so a running copy is
    /// never rewritten under its process; under `shared` another worktree's running copy is refused.
    func begin(_ app: PreparedApp, _ plan: LaunchPlan, in ctx: inout WorktreeContext) async throws -> StartedApp {
        // `simctl launch --terminate-running-process` replaces a running copy; `open -n` would start a second one.
        if app.target.device == nil, try await app.host.terminate(app.product) {
            builds.progress("stopped the running \(app.product.executableName)")
        }
        if app.target.device == nil {
            MacRefStore.forgetAll(in: ctx.paths)                                       // every ref is stale after a relaunch
            _ = try await isolation.prepareLaunch(built: app.built, device: app.target.name, in: ctx)
        }
        let launchedAt = builds.now()
        let appLog = ctx.paths.newArtifact(in: ctx.paths.logs, kind: "app", ext: "log", now: launchedAt)
        var started: StartedApp
        if let pid = try await app.host.launch(app.product, arguments: plan.arguments, environment: plan.environment, logFile: appLog) {
            started = StartedApp(pid: pid, appLog: appLog, launchedAt: launchedAt)
        } else if let crash = try await watcher.report(processName: app.product.executableName, pid: nil, since: launchedAt,
                                                       from: app.origin) {
            // A Mac app that dies before `ps` sees it (e.g. a fatalError in App.init) still leaves its crash report.
            started = StartedApp(pid: crash.pid, appLog: appLog, launchedAt: launchedAt)
            started.crashedAtLaunch = .exited(after: 0, crash: crash)
        } else {
            throw XcdError(.subprocessFailed, "\(app.product.executableName) did not start within 5s",
                           next: "read the app log: \(appLog)")
        }
        try await settle(started, app, in: &ctx)
        return started
    }

    /// Records the launch, so `xcd logs` and `xcd terminate` know it, then runs the post-launch hook.
    func settle(_ started: StartedApp, _ app: PreparedApp, in ctx: inout WorktreeContext) async throws {
        var state = try AppStateStore.load(ctx.paths)
        state.lastLaunch = LaunchRecord(target: app.target.name, bundleId: app.product.bundleId,
                                        processName: app.product.executableName, pid: started.pid, appLog: started.appLog,
                                        launchedAt: started.launchedAt)
        try AppStateStore.save(state, ctx.paths)
        guard started.crashedAtLaunch == nil else { return }
        do {
            try await builds.hooks?.run(.postLaunch, in: ctx, device: app.target.configDevice)
        } catch var error as XcdError where error.code == .hookFailed || error.code == .timeout {
            error.details.append("the app is still running (pid \(started.pid)); stop it with `xcd terminate`")
            throw error
        }
    }

    /// Watches a started app for `window`. An app that crashed at launch is not watched: its outcome is known.
    func outcome(of started: StartedApp, _ product: AppProduct, window: Duration) async throws -> LaunchOutcome {
        if let crashed = started.crashedAtLaunch { return crashed }
        builds.progress("launched \(product.bundleId) (pid \(started.pid)); watching \(DurationText.format(window)) for a crash")
        return try await watcher.watch(pid: started.pid, processName: product.executableName, window: window,
                                       launchedAt: started.launchedAt)
    }

    /// What a run report needs besides the app and how its launch went.
    struct RunFacts {
        let build: BuildReport?
        let crashWindow: Duration
        let ctx: WorktreeContext
    }

    static func report(_ outcome: LaunchOutcome, _ started: StartedApp, _ app: PreparedApp, _ facts: RunFacts) -> RunReport {
        let status: RunReport.Status
        var exitedAfter: Double?
        var crash: CrashReport?
        switch outcome {
        case .running:
            status = .running
        case .exited(let after, let report):
            status = report == nil ? .exited : .crashed
            exitedAfter = after
            crash = report
        }
        return RunReport(status: status, build: facts.build, target: app.target.name, targetSummary: app.target.summary,
                         bundleId: app.product.bundleId, pid: started.pid, appLog: started.appLog,
                         crashWindow: DurationText.seconds(facts.crashWindow), exitedAfter: exitedAfter, crash: crash,
                         appOutput: status == .running ? nil : Self.tail(of: started.appLog, lines: 10),
                         note: Self.note(for: app, in: facts.ctx),
                         worktree: facts.ctx.state.name)
    }

    static func tail(of file: String, lines count: Int) -> [String] {
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        return Array(text.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(count))
    }

    /// What a launch's result notes: for a Mac app, what every worktree's build of it shares, or under
    /// `isolation: suffix` the copy that runs with its own data; for a simulator, that it cannot write the
    /// app's output where this worktree is.
    static func note(for app: PreparedApp, in ctx: WorktreeContext) -> String? {
        guard app.target.device != nil else { return MacIsolationService.note(for: app.built, device: app.target.name, in: ctx) }
        return captureNote(worktreeRoot: ctx.location.worktreeRoot, target: app.target)
    }

    /// Simulators silently fail to write app output under temporary directories.
    static func captureNote(worktreeRoot: String, target: BuildTarget) -> String? {
        guard target.device != nil else { return nil }
        let temporary = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        guard temporary.contains(where: { worktreeRoot.hasPrefix($0) }) else { return nil }
        return "this worktree is in a temporary directory, where simulators can't write app output, so the app log stays empty; move the project elsewhere to capture it"
    }
}

/// How a command finds the app a target's build made.
extension RunService {
    /// The product the latest build recorded for this target, as the build made it: what a Mac app's isolated copy is
    /// made from. Isolation never changes the record.
    static func recordedProduct(for target: String, requested: String?, in ctx: WorktreeContext) throws -> AppProduct {
        guard let record = try AppStateStore.load(ctx.paths).builds[target] else {
            let flag = requested.map { " --device \($0)" } ?? ""
            throw XcdError(.appNotBuilt, "the app has not been built for \(target) in this worktree",
                           next: "run `xcd build\(flag)` (or `xcd run\(flag)`)")
        }
        guard let product = record.product else {
            throw XcdError(.usage, "scheme \(record.scheme) builds no app, so there is nothing to install or run",
                           next: "set schemes.app in .xcdev.yml to an app scheme, then run `xcd build`")
        }
        return product
    }

    /// `product(for:requested:in:)`, or nil when the target has no build or its scheme builds no app: for a command
    /// that says so in its own words.
    static func productIfBuilt(for target: String, in ctx: WorktreeContext) throws -> AppProduct? {
        do {
            return try product(for: target, requested: nil, in: ctx)
        } catch let error as XcdError where error.code == .appNotBuilt || error.code == .usage {
            return nil
        }
    }
}
