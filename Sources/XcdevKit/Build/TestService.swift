import Foundation

public struct TestOptions: Sendable {
    public var device: String?
    public var scheme: String?
    public var configuration: String?
    /// `-only-testing` identifiers, e.g. "AppTests/LoginTests/testValid" or "AppTests/works()".
    public var only: [String]
    public var skip: [String]
    public var timeout: Duration

    public init(device: String? = nil, scheme: String? = nil, configuration: String? = nil, only: [String] = [],
                skip: [String] = [], timeout: Duration = .seconds(3600)) {
        self.device = device
        self.scheme = scheme
        self.configuration = configuration
        self.only = only
        self.skip = skip
        self.timeout = timeout
    }
}

public struct TestService: Sendable {
    public let builds: BuildService
    /// Stops a UI runner that the project's own UI tests would fight over the device. Nil never stops one.
    public let detached: (any DetachedProcessLaunching)?

    public init(builds: BuildService, detached: (any DetachedProcessLaunching)? = nil) {
        self.builds = builds
        self.detached = detached
    }

    public func test(_ options: TestOptions, in ctx: inout WorktreeContext) async throws -> TestReport {
        try await builds.runPreBuild(device: options.device, in: &ctx)
        let plan = try await builds.plan(device: options.device, scheme: options.scheme, role: .test, in: &ctx)
        let stopped = await stopRunner(for: plan, options, in: ctx)
        let paths = ctx.paths
        let run = try await builds.runWithResultBundle(plan, kind: "test", paths: paths, timeout: options.timeout,
                                                       progress: "testing \(plan.scheme) on \(plan.target.summary)") { bundle in
            XcodebuildRequest(actions: [.test], container: plan.container, scheme: plan.scheme,
                              destination: plan.target.destination, configuration: options.configuration,
                              paths: paths, resultBundle: bundle, onlyTesting: options.only, skipTesting: options.skip)
        }
        let results = await testResults(bundle: run.bundle, xcode: plan.xcode)
        let verdict = Self.verdict(run, results)
        var report = TestReport(outcome: verdict.outcome, scheme: plan.scheme, target: plan.target.name,
                                targetSummary: plan.target.summary, seconds: builds.now().timeIntervalSince(run.started),
                                counts: results?.counts ?? TestCounts(total: 0, passed: 0, failed: 0, skipped: 0, expectedFailures: 0),
                                failures: results?.failures ?? [], buildErrors: verdict.buildErrors,
                                filtered: !options.only.isEmpty || !options.skip.isEmpty,
                                exampleFilter: options.only.first, resultBundle: run.resultBundle, log: run.log,
                                logTail: verdict.logTail, worktree: ctx.state.name)
        report.notes = stopped.map { "\($0) first: these tests may drive the UI themselves; the next `xcd ui` command starts it again" }
        return report
    }

    /// Stops this device's UI runner when the run includes UI tests, or xcd can't tell: the project's UI tests and
    /// the runner would both drive the device. A run of unit tests only leaves the runner alone.
    func stopRunner(for plan: BuildPlan, _ options: TestOptions, in ctx: WorktreeContext) async -> [String] {
        guard let detached, let device = plan.target.configDevice, Runners.load(ctx.paths.runnerFile(device: device)) != nil,
              UITestBundles.included(scheme: plan.scheme, container: plan.container, only: options.only, skip: options.skip) != false
        else { return [] }
        return await Runners.stopAll(in: ctx.paths, device: device, detached: detached)
    }

    /// What a finished xcodebuild run amounts to.
    struct Verdict {
        var outcome: TestReport.Outcome
        var buildErrors: [Diagnostic] = []
        /// The log's last lines, when xcodebuild failed without reporting an error.
        var logTail: [String]?
    }

    static func verdict(_ run: BuildService.ResultBundleRun, _ results: TestResults?) -> Verdict {
        let buildErrors = run.buildResults?.errors ?? []
        if !buildErrors.isEmpty { return Verdict(outcome: .buildFailed, buildErrors: buildErrors) }
        if let results, results.counts.total > 0 {
            guard !run.output.succeeded, results.counts.failed == 0, results.failures.isEmpty else {
                return Verdict(outcome: results.counts.failed > 0 || !run.output.succeeded ? .failed : .passed)
            }
            // The tests ran and none failed, yet xcodebuild failed (e.g. the test host crashed): say why.
            let (errors, tail) = BuildService.fallbackErrors(logFile: run.log, exitCode: run.output.exitCode)
            return Verdict(outcome: .failed, buildErrors: errors, logTail: tail)
        }
        guard !run.output.succeeded else { return Verdict(outcome: .noTests) }
        // The build succeeded yet no test ran (e.g. the test host crashed at launch): not a build failure.
        let (errors, tail) = BuildService.fallbackErrors(logFile: run.log, exitCode: run.output.exitCode)
        return Verdict(outcome: run.buildResults?.succeeded == true ? .failed : .buildFailed, buildErrors: errors, logTail: tail)
    }

    /// nil when the bundle is missing or has no readable summary.
    private func testResults(bundle: String, xcode: XcodeInstall) async -> TestResults? {
        guard FileManager.default.fileExists(atPath: bundle) else { return nil }
        func get(_ kind: String) async -> Data? {
            let invocation = Invocation.xcrun(["xcresulttool", "get", "test-results", kind, "--path", bundle],
                                              developerDir: xcode.developerDir)
            guard let out = try? await builds.runner.run(invocation), out.succeeded else { return nil }
            return out.stdout
        }
        guard let summary = await get("summary") else { return nil }
        return try? TestResults.parse(summary: summary, tests: await get("tests"))
    }
}
