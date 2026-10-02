import Foundation

public struct BuildOptions: Sendable {
    public var device: String?
    public var scheme: String?
    public var configuration: String?
    public var clean: Bool
    public var showWarnings: Bool
    public var timeout: Duration

    public init(device: String? = nil, scheme: String? = nil, configuration: String? = nil, clean: Bool = false,
                showWarnings: Bool = false, timeout: Duration = .seconds(1800)) {
        self.device = device
        self.scheme = scheme
        self.configuration = configuration
        self.clean = clean
        self.showWarnings = showWarnings
        self.timeout = timeout
    }
}

/// Everything needed to point xcodebuild at one target.
public struct BuildPlan: Sendable {
    public let xcode: XcodeInstall
    public let container: ProjectContainer
    public let target: BuildTarget
    public let scheme: String
}

public struct BuildService: Sendable {
    public let runner: any ProcessRunning
    public let provisioner: DeviceProvisioner
    /// One-line progress messages (the CLI prints them on stderr).
    public let progress: @Sendable (String) -> Void
    public let now: @Sendable () -> Date
    /// Runs `pre-build` before every build and test, and `post-launch` for RunService. Nil runs no hooks.
    public let hooks: HookRunner?

    public init(runner: any ProcessRunning, provisioner: DeviceProvisioner,
                progress: @escaping @Sendable (String) -> Void = { _ in },
                now: @escaping @Sendable () -> Date = { Date() }, hooks: HookRunner? = nil) {
        self.runner = runner
        self.provisioner = provisioner
        self.progress = progress
        self.now = now
        self.hooks = hooks
    }

    /// Runs the `pre-build` hook first, before the project, scheme, or simulator is resolved, so a hook can
    /// generate the project (xcodegen, tuist). Its context names the requested device, or the default one, but
    /// has no UDID, runtime, or app yet. Only Xcode is resolved first, for DEVELOPER_DIR.
    func runPreBuild(device requested: String?, in ctx: inout WorktreeContext) async throws {
        guard let hooks, ctx.config.hooks?.command(for: .preBuild) != nil else { return }
        _ = try await provisioner.ensureXcode(&ctx)
        let device = ctx.config.allDevices.isEmpty ? nil : try provisioner.deviceName(requested, config: ctx.config)
        try await hooks.run(.preBuild, config: ctx.config,
                            context: .beforeBuild(ctx: ctx, device: device, output: hooks.output), logs: ctx.paths)
    }

    /// Resolves the Xcode, the container, the target (cloning its simulator on first use), and the scheme.
    public func plan(device: String?, scheme: String?, role: SchemeRole,
                     in ctx: inout WorktreeContext) async throws -> BuildPlan {
        let xcode = try await provisioner.ensureXcode(&ctx)
        let container = try ProjectContainer.resolve(config: ctx.config, worktreeRoot: ctx.location.worktreeRoot)
        let target = try await provisioner.buildTarget(device, container: container, in: &ctx)
        let scheme = try await resolveScheme(scheme, role: role, container: container, xcode: xcode,
                                             config: ctx.config, paths: ctx.paths)
        return BuildPlan(xcode: xcode, container: container, target: target, scheme: scheme)
    }

    public func build(_ options: BuildOptions, in ctx: inout WorktreeContext) async throws -> BuildReport {
        try await runPreBuild(device: options.device, in: &ctx)
        let plan = try await plan(device: options.device, scheme: options.scheme, role: .app, in: &ctx)
        let paths = ctx.paths
        let run = try await runWithResultBundle(plan, kind: "build", paths: paths, timeout: options.timeout,
                                                progress: "building \(plan.scheme) for \(plan.target.summary)") { bundle in
            XcodebuildRequest(actions: options.clean ? [.clean, .build] : [.build], container: plan.container,
                              scheme: plan.scheme, destination: plan.target.destination,
                              configuration: options.configuration, paths: paths, resultBundle: bundle)
        }
        let results = run.buildResults

        var errors = results?.errors ?? []
        var logTail: [String]?
        if !run.output.succeeded && errors.isEmpty {
            (errors, logTail) = Self.fallbackErrors(logFile: run.log, exitCode: run.output.exitCode)
        }
        var product: AppProduct?
        if run.output.succeeded {
            let settings = try await runner.runChecked(run.request.buildSettingsInvocation(developerDir: plan.xcode.developerDir),
                                                       next: "run `xcodebuild -showBuildSettings` to see why")
            product = try BuildSettings.app(from: settings.stdout, preferredTarget: plan.scheme)
            var state = try AppStateStore.load(paths)
            state.builds[plan.target.name] = BuildRecord(scheme: plan.scheme, configuration: options.configuration,
                                                         product: product, finishedAt: now())
            try AppStateStore.save(state, paths)
        }
        return BuildReport(succeeded: run.output.succeeded, scheme: plan.scheme, target: plan.target.name,
                           targetSummary: plan.target.summary, seconds: now().timeIntervalSince(run.started),
                           errors: errors, warningCount: results?.warningCount ?? 0,
                           warnings: options.showWarnings ? (results?.warnings ?? []) : nil, product: product,
                           log: run.log, resultBundle: run.resultBundle, logTail: logTail, worktree: ctx.state.name)
    }

    /// `xcodebuild clean` for the app scheme (no destination, so nothing is cloned), or with `deep`,
    /// delete this worktree's DerivedData. Either way, recorded builds are forgotten.
    public func clean(scheme: String?, deep: Bool, in ctx: inout WorktreeContext) async throws -> CleanReport {
        let paths = ctx.paths
        var state = try AppStateStore.load(paths)
        state.builds = [:]
        if deep {
            let existed = FileManager.default.fileExists(atPath: paths.derivedData)
            if existed { try FileManager.default.removeItem(atPath: paths.derivedData) }
            try AppStateStore.save(state, paths)
            return CleanReport(deep: true, scheme: nil, removed: existed ? paths.derivedData : nil,
                               derivedData: paths.derivedData, log: nil, worktree: ctx.state.name)
        }
        let xcode = try await provisioner.ensureXcode(&ctx)
        let container = try ProjectContainer.resolve(config: ctx.config, worktreeRoot: ctx.location.worktreeRoot)
        let schemeName = try await resolveScheme(scheme, role: .app, container: container, xcode: xcode,
                                                config: ctx.config, paths: paths)
        let log = paths.newArtifact(in: paths.logs, kind: "clean", ext: "log", now: now())
        let request = XcodebuildRequest(actions: [.clean], container: container, scheme: schemeName, paths: paths)
        let output = try await runXcodebuild(request, xcode: xcode, log: log, timeout: .seconds(600))
        guard output.succeeded else {
            let (errors, tail) = Self.fallbackErrors(logFile: log, exitCode: output.exitCode)
            throw XcdError(.subprocessFailed, "xcodebuild clean failed (exit \(output.exitCode))",
                           next: "read the log, or delete the build folder with `xcd clean --deep`",
                           details: errors.map(\.text) + (tail ?? []) + ["log: \(log)"])
        }
        try AppStateStore.save(state, paths)
        return CleanReport(deep: false, scheme: schemeName, removed: nil, derivedData: paths.derivedData, log: log,
                           worktree: ctx.state.name)
    }

    func resolveScheme(_ requested: String?, role: SchemeRole, container: ProjectContainer, xcode: XcodeInstall,
                       config: XcdevConfig, paths: WorktreePaths) async throws -> String {
        if let scheme = Schemes.configured(requested, role: role, config: config) { return scheme }
        let listed = try? await runner.run(Schemes.listInvocation(container, paths: paths,
                                                                  developerDir: xcode.developerDir))
        let available = listed.map { Schemes.parseList($0.stdout) } ?? []
        if available.count == 1 { return available[0] }
        throw Schemes.missing(role: role, available: available)
    }

    /// One xcodebuild run that writes a log and a result bundle, with the bundle's build results.
    struct ResultBundleRun: Sendable {
        let started: Date
        let request: XcodebuildRequest
        let log: String
        let bundle: String
        let output: ProcessOutput
        /// nil when the bundle is missing or unreadable.
        let buildResults: BuildResults?

        /// The bundle's path if xcodebuild wrote it.
        var resultBundle: String? { FileManager.default.fileExists(atPath: bundle) ? bundle : nil }
    }

    /// Creates the timestamped `<kind>` log and result bundle paths, reports `progress` with the log path,
    /// runs the request `makeRequest` builds for that bundle, and reads the bundle's build results.
    func runWithResultBundle(_ plan: BuildPlan, kind: String, paths: WorktreePaths, timeout: Duration,
                             progress message: String,
                             makeRequest: (_ resultBundle: String) -> XcodebuildRequest) async throws -> ResultBundleRun {
        let started = now()
        let log = paths.newArtifact(in: paths.logs, kind: kind, ext: "log", now: started)
        let bundle = paths.newArtifact(in: paths.results, kind: kind, ext: "xcresult", now: started)
        let request = makeRequest(bundle)
        progress("\(message)  log: \(log)")
        let output = try await runXcodebuild(request, xcode: plan.xcode, log: log, timeout: timeout)
        let results = await buildResults(bundle: bundle, xcode: plan.xcode)
        return ResultBundleRun(started: started, request: request, log: log, bundle: bundle, output: output,
                               buildResults: results)
    }

    /// Runs xcodebuild with output going to `log`. A timeout error also names the log.
    func runXcodebuild(_ request: XcodebuildRequest, xcode: XcodeInstall, log: String,
                       timeout: Duration) async throws -> ProcessOutput {
        do {
            return try await runner.run(request.invocation(developerDir: xcode.developerDir, logFile: log, timeout: timeout))
        } catch var error as XcdError where error.code == .timeout {
            error.details.append("log: \(log)")
            throw error
        }
    }

    /// nil when the bundle is missing or unreadable; the exit code still decides success.
    func buildResults(bundle: String, xcode: XcodeInstall) async -> BuildResults? {
        guard FileManager.default.fileExists(atPath: bundle) else { return nil }
        let invocation = Invocation.xcrun(["xcresulttool", "get", "build-results", "--path", bundle],
                                          developerDir: xcode.developerDir)
        guard let out = try? await runner.run(invocation), out.succeeded else { return nil }
        return try? BuildResults.parse(out.stdout)
    }

    /// For failures without structured errors (bad scheme, destination, or arguments): xcodebuild's own
    /// `xcodebuild: error:` lines, or else one error plus the log's last 20 non-empty lines.
    static func fallbackErrors(logFile: String, exitCode: Int32) -> (errors: [Diagnostic], tail: [String]?) {
        let text = (try? String(contentsOfFile: logFile, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").map(String.init)
        let marker = "xcodebuild: error: "
        let errors = lines.compactMap { line -> Diagnostic? in
            guard let range = line.range(of: marker) else { return nil }
            return Diagnostic(.error, String(line[range.upperBound...]))
        }
        if !errors.isEmpty { return (errors, nil) }
        let tail = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(20)
        return ([Diagnostic(.error, "xcodebuild failed (exit \(exitCode)) without reporting an error; the log's last lines follow")],
                Array(tail))
    }
}
