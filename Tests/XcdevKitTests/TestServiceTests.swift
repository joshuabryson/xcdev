import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct TestServiceTests {
    let worktree = FakeWorktree(prefix: "xcd test")
    var fake: FakeProcessRunner { worktree.runner }
    static let passingSummary = #"{"result":"Passed","totalTestCount":3,"passedTests":3,"failedTests":0,"skippedTests":0,"expectedFailures":0,"testFailures":[]}"#

    func run(_ outcome: FakeXcodebuild.Outcome, _ options: TestOptions = TestOptions()) async throws -> (TestReport, FakeXcodebuild) {
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        let xcodebuild = FakeXcodebuild(runner: fake)
        xcodebuild.onRun(outcome)
        var ctx = try worktree.context(BuildServiceTests.config, container: "App.xcodeproj")
        let builds = BuildService(runner: fake, provisioner: worktree.provisioner,
                                  now: { Date(timeIntervalSince1970: 1_790_040_000) })
        return (try await TestService(builds: builds).test(options, in: &ctx), xcodebuild)
    }

    @Test func failingTestsAreReportedWithARerunCommand() async throws {
        defer { worktree.remove() }
        let (report, xcodebuild) = try await run(.init(exitCode: 65, log: "** TEST FAILED **\n",
                                                       buildResults: #"{"status":"succeeded","errors":[],"warnings":[]}"#,
                                                       testSummary: Fixture.string("test-results-summary-failed.json"),
                                                       testTree: Fixture.string("test-results-tests-failed.json")))
        #expect(report.outcome == .failed)
        #expect(report.counts.failed == 1 && report.counts.passed == 2 && report.counts.skipped == 1)
        #expect(report.failure?.code == .testFailed)
        #expect(report.failure?.message == "1 test failed")
        #expect(report.failure?.next == "fix the failing tests, then re-run them with `xcd test --only 'SampleAppTests/failsOnPurpose()'`")
        let args = try #require(xcodebuild.runs.first).arguments
        #expect(args.starts(with: ["xcodebuild", "test"]))
        #expect(args.contains("AppTests"))                         // schemes.test
        #expect(report.text.hasPrefix("tests failed  scheme=AppTests device=iphone (iPhone 18 Pro, iOS 27.0)  0.0s\npassed=2 failed=1 skipped=1\n/Users/dev/My Apps/SampleApp/SampleAppTests/SampleAppTests.swift:9: error: SampleAppTests/failsOnPurpose(): Expectation failed"))
    }

    @Test func filtersArePassedAndAPassingRunSucceeds() async throws {
        defer { worktree.remove() }
        let (report, xcodebuild) = try await run(.init(testSummary: Self.passingSummary),
                                                 TestOptions(only: ["AppTests/works()"], skip: ["AppTests/Slow"]))
        #expect(report.outcome == .passed && report.failure == nil)
        let args = try #require(xcodebuild.runs.first).arguments
        #expect(args.contains("-only-testing:AppTests/works()") && args.contains("-skip-testing:AppTests/Slow"))
        #expect(report.text.contains("\npassed=3 failed=0 skipped=0\n"))
    }

    @Test func aFilterThatMatchesNothingIsNotAPass() async throws {
        defer { worktree.remove() }
        let (report, _) = try await run(.init(log: "** TEST SUCCEEDED **\n",
                                              testSummary: Fixture.string("test-results-summary-empty.json")),
                                        TestOptions(only: ["AppTests/works"]))
        #expect(report.outcome == .noTests)
        #expect(report.failure?.code == .testFailed)
        #expect(report.failure?.message == "no tests ran")
        #expect(report.failure?.next == "check the --only/--skip identifiers; Swift Testing names need parentheses, e.g. `AppTests/works()`")
        #expect(report.text.hasPrefix("no tests ran  scheme=AppTests"))
    }

    @Test func compileErrorsInTestsAreBuildFailures() async throws {
        defer { worktree.remove() }
        let (report, _) = try await run(.init(exitCode: 65, buildResults: Fixture.string("build-results-failed.json"),
                                              testSummary: Fixture.string("test-results-summary-empty.json")))
        #expect(report.outcome == .buildFailed)
        #expect(report.buildErrors.count == 2)
        #expect(report.failure?.code == .buildFailed)
        #expect(report.failure?.next == "fix the errors and re-run `xcd test`")
    }

    @Test func unknownTestTargetPassesTheXcodebuildErrorThrough() async throws {
        defer { worktree.remove() }
        let (report, _) = try await run(.init(exitCode: 70, log: "xcodebuild: error: Failed to build project App with scheme AppTests.: Tests in the target “Nope” can’t be run because “Nope” isn’t a member of the specified test plan or scheme.\n"),
                                        TestOptions(only: ["Nope"]))
        #expect(report.outcome == .buildFailed)
        #expect(report.buildErrors.first?.message.hasPrefix("Failed to build project App with scheme AppTests.: Tests in the target “Nope”") == true)
    }

    @Test func aFailedRunWithoutFailingTestsShowsXcodebuildsErrors() async throws {
        defer { worktree.remove() }
        let (report, _) = try await run(.init(exitCode: 65,
                                              log: "Testing started\nxcodebuild: error: The test runner exited with code -1 before finishing.\n** TEST FAILED **\n",
                                              buildResults: #"{"status":"succeeded","errors":[],"warnings":[]}"#,
                                              testSummary: Self.passingSummary))
        #expect(report.outcome == .failed)
        #expect(report.failure?.code == .testFailed)
        #expect(report.failure?.message == "the test run failed without a failing test")
        #expect(report.failure?.next == "read the errors above and the log, then re-run `xcd test`")
        #expect(report.buildErrors.map(\.message) == ["The test runner exited with code -1 before finishing."])
        #expect(report.logTail == nil)
        #expect(report.text.contains("\npassed=3 failed=0 skipped=0\nerror: The test runner exited with code -1 before finishing.\n"))
    }

    @Test func aBuiltRunThatRanNoTestsIsATestFailureNotABuildFailure() async throws {
        defer { worktree.remove() }
        let (report, _) = try await run(.init(exitCode: 65,
                                              log: "Testing started\nxcodebuild: error: The test runner exited with code -1 before finishing.\n** TEST FAILED **\n",
                                              buildResults: #"{"status":"succeeded","errors":[],"warnings":[]}"#,
                                              testSummary: Fixture.string("test-results-summary-empty.json")))
        #expect(report.outcome == .failed)
        #expect(report.failure?.code == .testFailed)
        #expect(report.failure?.message == "the test run failed without a failing test")
        #expect(report.buildErrors.map(\.message) == ["The test runner exited with code -1 before finishing."])
    }

    @Test func aFailedRunWithoutFailingTestsOrErrorsShowsTheLogTail() async throws {
        defer { worktree.remove() }
        let (report, _) = try await run(.init(exitCode: 65, log: "Testing started\nRestarting after unexpected exit\n** TEST FAILED **\n",
                                              testSummary: Self.passingSummary))
        #expect(report.outcome == .failed)
        #expect(report.failure?.message == "the test run failed without a failing test")
        #expect(report.buildErrors.first?.message == "xcodebuild failed (exit 65) without reporting an error; the log's last lines follow")
        #expect(report.logTail == ["Testing started", "Restarting after unexpected exit", "** TEST FAILED **"])
    }

    /// Runs a passing `xcd test` with a UI runner recorded for `iphone`. Returns the report and what was stopped.
    func runBesideARunner(yaml: String, container: String, _ options: TestOptions = TestOptions()) async throws -> (TestReport, FakeDetachedProcesses, WorktreeContext) {
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        FakeXcodebuild(runner: fake).onRun(.init(testSummary: Self.passingSummary))
        var ctx = try worktree.context(yaml, container: container)
        let detached = FakeDetachedProcesses()
        let process = ProcessIdentity(pid: 4242, startTime: 1, arguments: ["xcodebuild", "test-without-building"])
        detached.adopt(process)
        try Runners.save(RunnerRecord(device: "iphone", udid: "U", process: process, token: "t", port: 1, runnerKey: "k", log: "/l",
                                      readyFile: "/r", startedAt: Date(), restarts: [], failed: false),
                         to: ctx.paths.runnerFile(device: "iphone"))
        let builds = BuildService(runner: fake, provisioner: worktree.provisioner, now: { Date(timeIntervalSince1970: 1_790_040_000) })
        let report = try await TestService(builds: builds, detached: detached).test(options, in: &ctx)
        return (report, detached, ctx)
    }

    static let phoneConfig = """
    version: 1
    project: Phone.xcodeproj
    schemes: { app: Phone, test: Phone }
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro" }
    """

    @Test func aRunThatMayDriveTheUIStopsTheUIRunnerFirst() async throws {
        defer { worktree.remove() }
        // App.xcodeproj is an empty folder here, so xcd can't tell what the scheme tests.
        let (report, detached, ctx) = try await runBesideARunner(yaml: BuildServiceTests.config, container: "App.xcodeproj")
        #expect(report.outcome == .passed && detached.stops == [.init(pid: 4242, signal: SIGTERM)] && ctx.paths.runnerFiles.isEmpty)
        #expect(report.notes.first == "stopped the iphone UI runner first: these tests may drive the UI themselves; the next `xcd ui` command starts it again")
        #expect(report.notes.filter { $0.contains("UI runner") }.count == 1)
        #expect(report.text.contains("\nnote: stopped the iphone UI runner first: these tests may drive the UI themselves;"))
    }

    @Test func aUnitTestRunLeavesTheUIRunnerAlone() async throws {
        defer { worktree.remove() }
        try Fixture.copy("ProjectFiles/Phone", to: worktree.root)              // its scheme tests PhoneTests, a unit-test bundle
        let (report, detached, ctx) = try await runBesideARunner(yaml: Self.phoneConfig, container: "Phone.xcodeproj")
        #expect(report.outcome == .passed && detached.stops.isEmpty && !report.notes.contains { $0.contains("UI runner") })
        #expect(ctx.paths.runnerFiles == [ctx.paths.runnerFile(device: "iphone")])
        #expect(!report.text.contains("UI runner"))
    }

    @Test func withoutARunnerNothingIsStoppedOrNoted() async throws {
        defer { worktree.remove() }
        let (report, _) = try await run(.init(testSummary: Self.passingSummary))
        #expect(!report.notes.contains { $0.contains("UI runner") } && !report.text.contains("UI runner"))
    }

    /// What `runLeasing` saw: the clone, where its lease is, what was on disk while xcodebuild ran, and the error
    /// `xcd test` threw, if any.
    struct LeasingRun {
        let udid: String
        let leases: DeviceLeases
        /// While xcodebuild ran: whether the lease existed, whether its lock was held, and whether a watchdog had started.
        let atRun: [Bool]
        let error: XcdError?
    }

    /// Runs a passing `xcd test` whose xcodebuild boots the clone, as a real one does, through a provisioner with idle
    /// sessions (without them when `sessions` is false). With `timesOut`, the run then throws as a timed-out xcodebuild does.
    func runLeasing(timesOut: Bool = false, sessions: Bool = true) async throws -> LeasingRun {
        let simulators = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        FakeXcodebuild(runner: fake).onRun(.init(testSummary: Self.passingSummary))
        let leases = DeviceLeases(globalPaths: GlobalPaths(base: worktree.root + "/home"), holds: LeaseHolds())
        let detached = FakeDetachedProcesses()
        let atRun = Shared<[Bool]>([])
        fake.stub(["xcrun", "xcodebuild", "test"]) { invocation in
            let udid = String((invocation.arguments.first { $0.hasPrefix("id=") } ?? "").dropFirst(3))
            atRun.set([leases.load(udid) != nil, FileLock.isHeld(at: leases.files(udid).lock), !detached.starts.isEmpty])
            simulators.setState("Booted", udid: udid)
            if timesOut { throw XcdError(.timeout, "xcodebuild did not finish within 1h") }
            return ProcessOutput(stdout: "** TEST SUCCEEDED **\n")
        }
        let provisioner = DeviceProvisioner(runner: fake, globalPaths: leases.globalPaths,
                                            sessions: sessions ? IdleSessions(leases: leases, detached: detached, executable: "/xcd") : nil)
        var ctx = try worktree.context(BuildServiceTests.config, container: "App.xcodeproj")
        let builds = BuildService(runner: fake, provisioner: provisioner, now: { Date(timeIntervalSince1970: 1_790_040_000) })
        var thrown: XcdError?
        do { _ = try await TestService(builds: builds).test(TestOptions(), in: &ctx) } catch let error as XcdError { thrown = error }
        let udid = try #require(ctx.state.devices["iphone"]?.udid)
        #expect(simulators.devices.first { $0.udid == udid }?.state == "Booted")
        return LeasingRun(udid: udid, leases: leases, atRun: atRun.value, error: thrown)
    }

    /// The session begins before xcodebuild runs: an `xcd test` that is interrupted or killed while xcodebuild runs still
    /// leaves a lease and a watchdog for the clone xcodebuild booted.
    @Test func aTestRunBeginsTheSessionBeforeXcodebuildRuns() async throws {
        defer { worktree.remove() }
        let run = try await runLeasing()
        defer { run.leases.holds.release(run.udid) }
        #expect(run.error == nil)
        #expect(run.atRun == [true, true, true])                     // the lease written, its lock held, the watchdog started
        #expect(run.leases.load(run.udid)?.device == "iphone")
    }

    /// A timed-out run, which comes after xcodebuild may have booted the clone, leaves the lease, and the timeout is
    /// still thrown.
    @Test func aTestRunThatThrowsStillLeavesTheLease() async throws {
        defer { worktree.remove() }
        let run = try await runLeasing(timesOut: true)
        defer { run.leases.holds.release(run.udid) }
        #expect(run.error?.code == .timeout && run.error?.message == "xcodebuild did not finish within 1h")
        #expect(run.leases.load(run.udid)?.device == "iphone")
    }

    @Test func aTestRunThroughAProvisionerWithoutSessionsLeasesNothing() async throws {
        defer { worktree.remove() }
        let run = try await runLeasing(sessions: false)
        #expect(run.error == nil)
        #expect(run.atRun == [false, false, false])
        #expect(run.leases.load(run.udid) == nil)
        #expect(!Disk.exists(run.leases.globalPaths.devicesDirectory))
    }
}
