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

    public init(builds: BuildService) { self.builds = builds }

    public func test(_ options: TestOptions, in ctx: inout WorktreeContext) async throws -> TestReport {
        let plan = try await builds.plan(device: options.device, scheme: options.scheme, role: .test, in: &ctx)
        let paths = ctx.paths
        let run = try await builds.runWithResultBundle(plan, kind: "test", paths: paths, timeout: options.timeout,
                                                       progress: "testing \(plan.scheme) on \(plan.target.summary)") { bundle in
            XcodebuildRequest(actions: [.test], container: plan.container, scheme: plan.scheme,
                              destination: plan.target.destination, configuration: options.configuration,
                              paths: paths, resultBundle: bundle, onlyTesting: options.only, skipTesting: options.skip)
        }
        let results = await testResults(bundle: run.bundle, xcode: plan.xcode)

        var buildErrors = run.buildResults?.errors ?? []
        var logTail: [String]?
        let outcome: TestReport.Outcome
        if !buildErrors.isEmpty {
            outcome = .buildFailed
        } else if let results, results.counts.total > 0 {
            outcome = results.counts.failed > 0 || !run.output.succeeded ? .failed : .passed
            if !run.output.succeeded && results.counts.failed == 0 && results.failures.isEmpty {
                // The tests ran and none failed, yet xcodebuild failed (e.g. the test host crashed): say why.
                (buildErrors, logTail) = BuildService.fallbackErrors(logFile: run.log, exitCode: run.output.exitCode)
            }
        } else if !run.output.succeeded {
            // The build succeeded yet no test ran (e.g. the test host crashed at launch): not a build failure.
            outcome = run.buildResults?.succeeded == true ? .failed : .buildFailed
            (buildErrors, logTail) = BuildService.fallbackErrors(logFile: run.log, exitCode: run.output.exitCode)
        } else {
            outcome = .noTests
        }
        return TestReport(outcome: outcome, scheme: plan.scheme, target: plan.target.name,
                          targetSummary: plan.target.summary, seconds: builds.now().timeIntervalSince(run.started),
                          counts: results?.counts ?? TestCounts(total: 0, passed: 0, failed: 0, skipped: 0, expectedFailures: 0),
                          failures: results?.failures ?? [], buildErrors: buildErrors,
                          filtered: !options.only.isEmpty || !options.skip.isEmpty,
                          exampleFilter: options.only.first, resultBundle: run.resultBundle, log: run.log,
                          logTail: logTail, worktree: ctx.state.name)
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
