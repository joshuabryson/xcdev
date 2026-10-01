import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct LogsTests {
    let worktree = FakeWorktree(prefix: "xcd logs")
    var fake: FakeProcessRunner { worktree.runner }
    var dir: String { worktree.root }
    static let product = AppProduct(path: "/dd/SampleApp.app", bundleId: "dev.xcdev.SampleApp",
                                    executableName: "SampleApp", platform: "iphonesimulator")
    let banner = "Filtering the log data using \"process == \\\"SampleApp\\\"\"\n"

    func context(product: AppProduct? = LogsTests.product, target: String = "iphone", clone: Bool = true) throws -> WorktreeContext {
        var ctx = try worktree.context(BuildServiceTests.config + "\nlogs: { maxFollow: 1m }", container: "App.xcodeproj")
        if clone {
            ctx.state.devices["iphone"] = ProvisionedDevice(udid: "U1", deviceType: "iPhone 18 Pro", deviceTypeIdentifier: "t",
                                                            runtime: "iOS 27.0", runtimeIdentifier: "r")
        }
        if let product {
            try AppStateStore.save(AppState(builds: [target: BuildRecord(scheme: "App", configuration: nil, product: product,
                                                                          finishedAt: Date())]), ctx.paths)
        }
        return ctx
    }

    var service: LogService { LogService(runner: fake, provisioner: worktree.provisioner) }

    @Test func parsesRecordedNDJSONSkippingBannerActivitiesAndTrailer() {
        let entries = LogParser.parse(banner + Fixture.string("log-show.ndjson"))
        #expect(entries.map(\.message) == ["sample log line", "sample log line", "BUG in libdispatch: 26A434 24A434 - 612 - 0x4"])
        #expect(entries[0].text == "19:55:23.213 Info [dev.xcdev.SampleApp:app] sample log line")
        #expect(entries[2].text == "19:55:23.212 Default [com.apple.libsystem.libdispatch] BUG in libdispatch: 26A434 24A434 - 612 - 0x4")
    }

    @Test func predicateQuotesTheProcessNameAndHidesAppleSubsystems() {
        #expect(LogQuery.predicate(processName: #"My "App""#, includeSystem: false)
                == #"process == "My \"App\"" AND NOT (subsystem BEGINSWITH "com.apple.")"#)
        #expect(LogQuery.predicate(processName: "App", includeSystem: true) == #"process == "App""#)
    }

    @Test func showAndStreamArguments() {
        let pred = LogQuery.predicate(processName: "App", includeSystem: false)
        #expect(LogQuery.arguments(LogOptions(since: .seconds(90)), processName: "App")
                == ["show", "--style", "ndjson", "--last", "90s", "--predicate", pred, "--info"])
        #expect(LogQuery.arguments(LogOptions(level: .debug), processName: "App")
                == ["show", "--style", "ndjson", "--last", "120s", "--predicate", pred, "--info", "--debug"])
        #expect(LogQuery.arguments(LogOptions(level: .default), processName: "App")
                == ["show", "--style", "ndjson", "--last", "120s", "--predicate", pred])
        #expect(LogQuery.arguments(LogOptions(follow: .milliseconds(2500)), processName: "App")
                == ["stream", "--style", "ndjson", "--level", "info", "--timeout", "3", "--predicate", pred])
    }

    @Test func showsTheSimulatorsLogForTheAppProcess() async throws {
        defer { worktree.remove() }
        fake.stub(["xcrun", "simctl", "spawn"], stdout: banner + Fixture.string("log-show.ndjson"),
                  stderr: "getpwuid_r did not find a match for uid 501\n")
        var ctx = try context()
        let report = try await service.logs(LogOptions(), in: &ctx)
        let call = try #require(fake.calls.first)
        #expect(call.arguments == ["simctl", "spawn", "U1", "log", "show", "--style", "ndjson", "--last", "120s",
                                   "--predicate", LogQuery.predicate(processName: "SampleApp", includeSystem: false), "--info"])
        #expect(call.environment["DEVELOPER_DIR"] == "/Applications/Xcode.app/Contents/Developer")
        #expect(report.entries.count == 3 && report.total == 3)
        #expect(report.text.hasPrefix("3 log entries  process=SampleApp device=iphone last 2m00s\n19:55:23.213 Info"))
    }

    @Test func grepAndLimitNarrowTheOutput() async throws {
        defer { worktree.remove() }
        fake.stub(["xcrun", "simctl", "spawn"], stdout: Fixture.string("log-show.ndjson"))
        var ctx = try context()
        let report = try await service.logs(LogOptions(grep: "SAMPLE", limit: 1), in: &ctx)
        #expect(report.entries.map(\.message) == ["sample log line"] && report.total == 2)
        #expect(report.text.hasPrefix("1 log entry  process=SampleApp device=iphone last 2m00s  (showing the last 1 of 2; narrow with --grep or --since, or raise --limit)"))
    }

    @Test func emptyResultsExplainWhereMessagesMightBe() async throws {
        defer { worktree.remove() }
        fake.stub(["xcrun", "simctl", "spawn"], stdout: #"{"count":0,"finished":1}"# + "\n")
        var ctx = try context()
        let report = try await service.logs(LogOptions(), in: &ctx)
        #expect(report.text == """
        no log entries  process=SampleApp device=iphone last 2m00s
        hint: Logger .debug messages need --level debug; Apple framework messages need --system
        """)
    }

    @Test func followStreamsUntilItsDeadlineIntoAFile() async throws {
        defer { worktree.remove() }
        fake.stub(["xcrun", "simctl", "spawn"], stdout: banner + Fixture.string("log-show.ndjson"))
        var ctx = try context()
        let report = try await service.logs(LogOptions(follow: .seconds(30)), in: &ctx)
        let call = try #require(fake.calls.first)
        #expect(call.arguments.contains("stream") && call.stopAtTimeout && call.timeout == .seconds(45))
        #expect(call.outputFile == report.file && report.file?.hasPrefix(dir + "/.xcdev/logs/") == true)
        #expect(report.entries.count == 3)
        #expect(report.text.hasPrefix("3 log entries  process=SampleApp device=iphone followed 30.0s"))
    }

    @Test func followStoppedAtItsDeadlineIsNotAFailure() async throws {
        defer { worktree.remove() }
        // `log stream` outlived its own --timeout, so the runner sent SIGTERM at the deadline.
        fake.stub(["xcrun", "simctl", "spawn"]) { _ in
            var output = ProcessOutput(exitCode: 15, stdout: Fixture.string("log-show.ndjson"))
            output.stoppedAtDeadline = true
            return output
        }
        var ctx = try context()
        let report = try await service.logs(LogOptions(follow: .seconds(5)), in: &ctx)
        #expect(report.entries.count == 3)
        #expect(report.text.hasPrefix("3 log entries  process=SampleApp device=iphone followed 5.0s"))
    }

    @Test func followThatFailsBeforeItsDeadlineReportsTheCapturedError() async throws {
        defer { worktree.remove() }
        fake.stub(["xcrun", "simctl", "spawn"], exitCode: 64, stderr: "log: invalid predicate\n")
        var ctx = try context()
        let error = await #expect(throws: XcdError.self) { try await service.logs(LogOptions(follow: .seconds(5)), in: &ctx) }
        #expect(error?.code == .subprocessFailed)
        #expect(error?.details.contains("log: invalid predicate") == true)
    }

    @Test func followLongerThanTheConfiguredMaximumIsRefused() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        let error = await #expect(throws: XcdError.self) { try await service.logs(LogOptions(follow: .seconds(120)), in: &ctx) }
        #expect(error?.code == .usage)
        #expect(error?.message == "--for 2m00s is longer than logs.maxFollow (1m00s)")
        #expect(fake.calls.isEmpty)
    }

    @Test func macAppsUseTheHostLog() async throws {
        defer { worktree.remove() }
        fake.stub(["log", "show"], stdout: Fixture.string("log-show.ndjson"))
        var ctx = try context(product: AppProduct(path: "/dd/Mac.app", bundleId: "dev.x.Mac", executableName: "Mac",
                                                  platform: "macosx"), target: "mac")
        let report = try await service.logs(LogOptions(device: "mac"), in: &ctx)
        #expect(fake.calls.first?.executable == "/usr/bin/log")
        #expect(report.processName == "Mac")
    }

    @Test func aShutDownSimulatorSaysToBootIt() async throws {
        defer { worktree.remove() }
        fake.stub(["xcrun", "simctl", "spawn"], exitCode: 149, stderr: "Unable to lookup in current state: Shutdown")
        var ctx = try context()
        let error = await #expect(throws: XcdError.self) { try await service.logs(LogOptions(), in: &ctx) }
        #expect(error?.code == .simulatorFailed)
        #expect(error?.message == "iphone's simulator is shut down, so its log can't be read")
        #expect(error?.next == "boot it with `xcd sim boot --device iphone` (earlier entries are kept)")
        let follow = await #expect(throws: XcdError.self) { try await service.logs(LogOptions(follow: .seconds(5)), in: &ctx) }
        #expect(follow?.code == .simulatorFailed)
    }

    @Test func notBuiltOrNeverLaunched() async throws {
        defer { worktree.remove() }
        var unbuilt = try context(product: nil)
        let error = await #expect(throws: XcdError.self) { try await service.logs(LogOptions(), in: &unbuilt) }
        #expect(error?.code == .appNotBuilt)
        #expect(error?.next == "run `xcd build` (or `xcd run`)")
        let app = await #expect(throws: XcdError.self) { try await service.logs(LogOptions(appOutput: true), in: &unbuilt) }
        #expect(app?.code == .appNotBuilt)
        #expect(app?.message == "nothing has been launched in this worktree yet")
        #expect(app?.next == "run `xcd run` (or `xcd launch`), then `xcd logs --app`")
    }

    @Test func appOutputShowsTheLatestLaunchsCapturedOutput() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        let log = dir + "/.xcdev/app.log"          // .xcdev exists: context() saved app.json
        try "one\n\ntwo\nthree\n".write(toFile: log, atomically: true, encoding: .utf8)
        var state = try AppStateStore.load(ctx.paths)
        state.lastLaunch = LaunchRecord(target: "iphone", bundleId: "dev.xcdev.SampleApp", processName: "SampleApp", pid: 1,
                                        appLog: log, launchedAt: Date())
        try AppStateStore.save(state, ctx.paths)
        let report = try await service.logs(LogOptions(limit: 2, appOutput: true), in: &ctx)
        #expect(report.lines == ["two", "three"] && report.total == 3)
        #expect(report.text == """
        2 lines of app output  process=SampleApp device=iphone latest launch  (showing the last 2 of 3; narrow with --grep or --since, or raise --limit)
        file: \(log)
        two
        three
        """)
    }
}
