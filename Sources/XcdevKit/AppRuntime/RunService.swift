import Foundation

public struct LaunchOptions: Sendable {
    public var preset: String?
    public var arguments: [String]
    public var environment: [String: String]
    public var crashWindow: Duration

    public init(preset: String? = nil, arguments: [String] = [], environment: [String: String] = [:],
                crashWindow: Duration = .seconds(5)) {
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

public struct RunService: Sendable {
    public let builds: BuildService
    public let watcher: CrashWatcher
    let sleep: @Sendable (Duration) async throws -> Void

    public init(builds: BuildService, watcher: CrashWatcher,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.builds = builds
        self.watcher = watcher
        self.sleep = sleep
    }

    /// Build (unless `noBuild`), boot, install, launch, and watch for a crash.
    public func run(_ build: BuildOptions, noBuild: Bool, launch: LaunchOptions,
                    in ctx: inout WorktreeContext) async throws -> RunReport {
        let (arguments, environment) = try launch.resolved(config: ctx.config)
        var buildReport: BuildReport?
        if !noBuild {
            let report = try await builds.build(build, in: &ctx)
            guard report.succeeded else { return RunReport(buildFailed: report, worktree: ctx.state.name) }
            buildReport = report
        }
        let (target, product, host) = try await prepare(build.device, boot: true, in: &ctx)
        try await host.install(product)
        return try await start(product, target: target, host: host, arguments: arguments, environment: environment,
                               crashWindow: launch.crashWindow, build: buildReport, in: &ctx)
    }

    /// Launch the already-installed build (booting the clone if needed) and watch for a crash.
    public func launch(device: String?, options: LaunchOptions, in ctx: inout WorktreeContext) async throws -> RunReport {
        let (arguments, environment) = try options.resolved(config: ctx.config)
        let (target, product, host) = try await prepare(device, boot: true, in: &ctx)
        return try await start(product, target: target, host: host, arguments: arguments, environment: environment,
                               crashWindow: options.crashWindow, build: nil, in: &ctx)
    }

    public func install(device: String?, in ctx: inout WorktreeContext) async throws -> AppActionReport {
        let (target, product, host) = try await prepare(device, boot: true, in: &ctx)
        guard target.device != nil else {
            return AppActionReport(action: "nothing to install", bundleId: product.bundleId, target: target.name,
                                   note: "macOS apps run from this worktree's DerivedData", worktree: ctx.state.name)
        }
        try await host.install(product)
        return AppActionReport(action: "installed", bundleId: product.bundleId, target: target.name, note: nil,
                               worktree: ctx.state.name)
    }

    public func uninstall(device: String?, in ctx: inout WorktreeContext) async throws -> AppActionReport {
        let (target, product, host) = try await prepare(device, boot: true, in: &ctx)
        guard target.device != nil else {
            return AppActionReport(action: "nothing to uninstall", bundleId: product.bundleId, target: target.name,
                                   note: "macOS apps run from this worktree's DerivedData", worktree: ctx.state.name)
        }
        try await host.uninstall(product)
        return AppActionReport(action: "uninstalled", bundleId: product.bundleId, target: target.name, note: nil,
                               worktree: ctx.state.name)
    }

    public func terminate(device: String?, in ctx: inout WorktreeContext) async throws -> AppActionReport {
        let (target, product, host) = try await prepare(device, boot: false, in: &ctx)
        let stopped = try await host.terminate(product)
        return AppActionReport(action: stopped ? "terminated" : "not running", bundleId: product.bundleId,
                               target: target.name, note: nil, worktree: ctx.state.name)
    }

    /// The latest build's app for this target, or `app_not_built` naming the build to run.
    public static func product(for target: String, requested: String?, in ctx: WorktreeContext) throws -> AppProduct {
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

    private func prepare(_ device: String?, boot: Bool,
                         in ctx: inout WorktreeContext) async throws -> (BuildTarget, AppProduct, any AppHost) {
        let container = try ProjectContainer.resolve(config: ctx.config, worktreeRoot: ctx.location.worktreeRoot)
        let name = try builds.provisioner.targetName(device, container: container, config: ctx.config)
        let product = try Self.product(for: name, requested: device, in: ctx)
        let target = try await builds.provisioner.buildTarget(device, container: container, in: &ctx)
        guard let clone = target.device else {
            return (target, product, MacAppHost(runner: builds.runner, sleep: sleep))
        }
        if boot { _ = try await builds.provisioner.boot(target.name, in: &ctx) }
        return (target, product, SimulatorAppHost(simctl: builds.provisioner.simctl(for: ctx), udid: clone.udid))
    }

    private func start(_ product: AppProduct, target: BuildTarget, host: any AppHost, arguments: [String],
                       environment: [String: String], crashWindow: Duration, build: BuildReport?,
                       in ctx: inout WorktreeContext) async throws -> RunReport {
        let paths = ctx.paths
        // `simctl launch --terminate-running-process` replaces a running copy; `open -n` would start a second one.
        if target.device == nil, try await host.terminate(product) {
            builds.progress("stopped the running \(product.executableName)")
        }
        // Taken before the launch: crash reports are matched to launches written at or after this time.
        let launchedAt = builds.now()
        let appLog = paths.newArtifact(in: paths.logs, kind: "app", ext: "log", now: launchedAt)
        let pid: Int32
        var crashedAtLaunch: LaunchOutcome?
        if let launched = try await host.launch(product, arguments: arguments, environment: environment, logFile: appLog) {
            pid = launched
        } else if let crash = try await watcher.report(processName: product.executableName, pid: nil, since: launchedAt) {
            // A Mac app that dies before `ps` sees it (e.g. a fatalError in App.init) still leaves its crash report.
            pid = crash.pid
            crashedAtLaunch = .exited(after: 0, crash: crash)
        } else {
            throw XcdError(.subprocessFailed, "\(product.executableName) did not start within 5s",
                           next: "read the app log: \(appLog)")
        }
        var state = try AppStateStore.load(paths)
        state.lastLaunch = LaunchRecord(target: target.name, bundleId: product.bundleId, processName: product.executableName,
                                        pid: pid, appLog: appLog, launchedAt: launchedAt)
        try AppStateStore.save(state, paths)
        let outcome: LaunchOutcome
        if let crashedAtLaunch {
            outcome = crashedAtLaunch
        } else {
            builds.progress("launched \(product.bundleId) (pid \(pid)); watching \(DurationText.format(crashWindow)) for a crash")
            outcome = try await watcher.watch(pid: pid, processName: product.executableName, window: crashWindow,
                                          launchedAt: launchedAt)
        }
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
        return RunReport(status: status, build: build, target: target.name, targetSummary: target.summary,
                         bundleId: product.bundleId, pid: pid, appLog: appLog,
                         crashWindow: DurationText.seconds(crashWindow), exitedAfter: exitedAfter, crash: crash,
                         appOutput: status == .running ? nil : Self.tail(of: appLog, lines: 10),
                         note: Self.captureNote(worktreeRoot: ctx.location.worktreeRoot, target: target),
                         worktree: ctx.state.name)
    }

    static func tail(of file: String, lines count: Int) -> [String] {
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        return Array(text.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(count))
    }

    /// Simulators silently fail to write app output under temporary directories.
    static func captureNote(worktreeRoot: String, target: BuildTarget) -> String? {
        guard target.device != nil else { return nil }
        let temporary = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        guard temporary.contains(where: { worktreeRoot.hasPrefix($0) }) else { return nil }
        return "this worktree is in a temporary directory, where simulators can't write app output, so the app log stays empty; move the project elsewhere to capture it"
    }
}
