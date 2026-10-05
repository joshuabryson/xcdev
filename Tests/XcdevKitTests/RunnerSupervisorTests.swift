import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct RunnerSupervisorTests {
    let worktree = FakeWorktree(prefix: "xcd supervisor")
    static let yaml = """
    version: 1
    project: App.xcodeproj
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro" }
    """

    /// Writes the ready file as the real runner would, taking the path from the invocation's environment.
    static let writesReady: @Sendable (Invocation, String) throws -> Void = { invocation, log in
        try FileManager.default.createDirectory(atPath: (log as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let ready = invocation.environment["TEST_RUNNER_XCD_READY_FILE"]!
        try #"{"port": 51234}"#.write(toFile: ready, atomically: true, encoding: .utf8)
    }

    func setup(detached: FakeDetachedProcesses = FakeDetachedProcesses(onStart: writesReady),
               transport: FakeRunnerTransport = FakeRunnerTransport(), now: Date = Date(timeIntervalSince1970: 1_791_100_000),
               sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in _ = duration }) throws -> (RunnerSupervisor, WorktreeContext) {
        _ = try FakeSimulators(runner: worktree.runner, catalogJSON: Fixture.string("simctl-list.json"))
        worktree.runner.stub(["xcrun", "xcodebuild", "build-for-testing"]) { invocation in
            let derived = invocation.arguments[invocation.arguments.firstIndex(of: "-derivedDataPath")! + 1]
            try FileManager.default.createDirectory(atPath: derived + "/Build/Products", withIntermediateDirectories: true)
            let plist: [String: Any] = ["TestConfigurations": [["TestTargets": [["TestTimeoutsEnabled": false]]]]]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: derived + "/Build/Products/XcdRunner_XcdRunner_iphonesimulator27.0-arm64-x86_64.xctestrun"))
            return ProcessOutput()
        }
        let paths = GlobalPaths(base: worktree.root + "/home")
        let supervisor = RunnerSupervisor(provisioner: worktree.provisioner, builder: RunnerBuilder(runner: worktree.runner, globalPaths: paths),
                                          detached: detached, client: RunnerClient(transport: transport), globalPaths: paths,
                                          now: { now }, sleep: sleep)
        return (supervisor, try worktree.context(Self.yaml))
    }

    @Test func startsARunnerAndRecordsIt() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: Self.writesReady)
        var (supervisor, ctx) = try setup(detached: detached)
        let session = try await supervisor.session(device: nil, in: &ctx)
        #expect(session.port == 51234 && session.device == "iphone" && !session.restarted && !session.token.isEmpty)
        let start = try #require(detached.starts.first)
        #expect(start.invocation.commandLine.contains("xcodebuild test-without-building -xctestrun"))
        #expect(start.invocation.arguments.contains("id=\(session.udid)"))
        #expect(start.invocation.environment["TEST_RUNNER_XCD_TOKEN"] == session.token)
        #expect(start.invocation.environment["DEVELOPER_DIR"] == "/Applications/Xcode.app/Contents/Developer")
        #expect(start.log == ctx.paths.logs + "/ui-runner-iphone.log")
        let record = try #require(Runners.load(ctx.paths.runnerFile(device: "iphone")))
        #expect(record.port == 51234 && record.process == start.identity && record.udid == session.udid && !record.failed)
        #expect(record.runnerKey == "27A266a-" + RunnerSource.hash)
    }

    @Test func attachesToAHealthyRunner() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: Self.writesReady)
        var (supervisor, ctx) = try setup(detached: detached)
        let first = try await supervisor.session(device: nil, in: &ctx)
        let second = try await supervisor.session(device: nil, in: &ctx)
        #expect(detached.starts.count == 1 && detached.stops.isEmpty)
        #expect(second.port == first.port && second.token == first.token && !second.restarted)
    }

    @Test func aLingeringXcodebuildWithADeadRunnerIsRestarted() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: Self.writesReady)
        let transport = FakeRunnerTransport()
        var (supervisor, ctx) = try setup(detached: detached, transport: transport)
        let first = try await supervisor.session(device: nil, in: &ctx)
        let answers = Counter()
        transport.setHandler { path, body in                         // the old runner is dead; the new one answers
            if answers.increment() == 1 { throw RunnerUnreachable(reason: "refused") }
            return try FakeRunnerTransport.healthy(path, body)
        }
        let second = try await supervisor.session(device: nil, in: &ctx)
        #expect(second.restarted && second.token != first.token)
        #expect(detached.stops.map(\.signal) == [SIGTERM] && detached.starts.count == 2)
        #expect(Runners.load(ctx.paths.runnerFile(device: "iphone"))?.restarts.count == 1)
    }

    @Test func aRecordWhosePidWasReusedIsNeverSignalled() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: Self.writesReady)
        var (supervisor, ctx) = try setup(detached: detached)
        let stale = RunnerRecord(device: "iphone", udid: "OLD", process: ProcessIdentity(pid: 777, startTime: 100, arguments: ["xcodebuild", "test-without-building"]),
                                 token: "old", port: 40000, runnerKey: "old", log: "/l", readyFile: "/r",
                                 startedAt: Date(timeIntervalSince1970: 0), restarts: [], failed: false)
        try Runners.save(stale, to: ctx.paths.runnerFile(device: "iphone"))
        detached.adopt(ProcessIdentity(pid: 777, startTime: 999, arguments: ["vim"]))      // pid 777 is someone else now
        let session = try await supervisor.session(device: nil, in: &ctx)
        #expect(detached.stops.isEmpty && detached.starts.count == 1 && session.token != "old")
    }

    @Test func aRecordWhoseProcessNowRunsAnotherProgramIsNeverSignalled() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: Self.writesReady)
        var (supervisor, ctx) = try setup(detached: detached)
        let recorded = ProcessIdentity(pid: 778, startTime: 100, arguments: ["xcodebuild", "test-without-building"])
        let stale = RunnerRecord(device: "iphone", udid: "OLD", process: recorded, token: "old", port: 40000, runnerKey: "old",
                                 log: "/l", readyFile: "/r", startedAt: Date(timeIntervalSince1970: 0), restarts: [], failed: false)
        try Runners.save(stale, to: ctx.paths.runnerFile(device: "iphone"))
        detached.adopt(ProcessIdentity(pid: 778, startTime: 100, arguments: ["vim"]))      // same pid and start time, other program
        let session = try await supervisor.session(device: nil, in: &ctx)
        #expect(detached.stops.isEmpty && detached.starts.count == 1 && session.token != "old")
    }

    @Test func aRunnerBuiltByAnotherXcodeIsReplaced() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: Self.writesReady)
        var (supervisor, ctx) = try setup(detached: detached)
        _ = try await supervisor.session(device: nil, in: &ctx)
        var record = try #require(Runners.load(ctx.paths.runnerFile(device: "iphone")))
        record.runnerKey = "26F100-oldhash"
        try Runners.save(record, to: ctx.paths.runnerFile(device: "iphone"))
        let session = try await supervisor.session(device: nil, in: &ctx)
        #expect(session.restarted && detached.starts.count == 2 && detached.stops.count == 1)
    }

    @Test func twoRestartsWithinAMinuteMarkItFailedUntilStopped() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: Self.writesReady)
        var (supervisor, ctx) = try setup(detached: detached)
        _ = try await supervisor.session(device: nil, in: &ctx)
        _ = try await supervisor.session(device: nil, in: &ctx, restart: true)
        let error = await #expect(throws: XcdError.self) { _ = try await supervisor.session(device: nil, in: &ctx, restart: true) }
        #expect(error?.code == .runnerFailed && error?.message.contains("keeps stopping") == true)
        #expect(error?.next == "run `xcd ui stop`, then `xcd doctor`")
        let again = await #expect(throws: XcdError.self) { _ = try await supervisor.session(device: nil, in: &ctx) }
        #expect(again?.code == .runnerFailed)
        #expect(try await supervisor.stop(device: nil, in: ctx).count == 1)
        #expect(try await supervisor.session(device: nil, in: &ctx).port == 51234)
    }

    @Test func aStartThatNeverBecomesReadyIsStoppedAndReported() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: { _, log in
            try FileManager.default.createDirectory(atPath: (log as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "Testing started\n".write(toFile: log, atomically: true, encoding: .utf8)
        })
        var (supervisor, ctx) = try setup(detached: detached)
        let error = await #expect(throws: XcdError.self) { _ = try await supervisor.session(device: nil, in: &ctx) }
        #expect(error?.code == .runnerFailed && error?.message.contains("did not start within") == true)
        #expect(error?.details.contains("Testing started") == true)
        #expect(detached.stops.map(\.signal) == [SIGTERM])
        #expect(Runners.load(ctx.paths.runnerFile(device: "iphone")) == nil)
    }

    @Test func anEarlyDeviceNotFoundExitIsRetriedOnce() async throws {
        defer { worktree.remove() }
        let attempts = Counter()
        let detached = FakeDetachedProcesses(onStart: { invocation, log in
            try FileManager.default.createDirectory(atPath: (log as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if attempts.increment() == 1 {
                try "xcodebuild: error: Unable to find a device matching the provided destination specifier\n"
                    .write(toFile: log, atomically: true, encoding: .utf8)
            } else {
                try Self.writesReady(invocation, log)
            }
        })
        // The first xcodebuild exits at once: the supervisor's first sleep finds it gone.
        var (supervisor, ctx) = try setup(detached: detached, sleep: { _ in
            if attempts.value == 1, let pid = detached.starts.first?.identity.pid { detached.exit(pid: pid) }
        })
        let session = try await supervisor.session(device: nil, in: &ctx)
        #expect(session.port == 51234 && detached.starts.count == 2)
    }

    @Test func concurrentSessionsStartOneRunner() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: Self.writesReady)
        let (supervisor, ctx) = try setup(detached: detached)
        var booted = ctx
        _ = try await worktree.provisioner.boot("iphone", in: &booted)             // both tasks see the same clone
        let state = booted
        @Sendable func one() async throws -> RunnerSession {
            var copy = state
            return try await supervisor.session(device: nil, in: &copy)
        }
        async let a = one()
        async let b = one()
        let (first, second) = try await (a, b)
        #expect(detached.starts.count == 1 && first.token == second.token)
    }

    @Test func aCloneThisCommandBootedGetsTheLongTimeout() {
        #expect(RunnerSupervisor.startTimeout(wasBooted: true) == .seconds(120))
        #expect(RunnerSupervisor.startTimeout(wasBooted: false) == .seconds(600))
    }

    @Test func onlyIOSClonesCanBeDriven() {
        let watch = ProvisionedDevice(udid: "W", deviceType: "Apple Watch Series 12 (46mm)", deviceTypeIdentifier: "t",
                                      runtime: "watchOS 27.0", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-27-0")
        let error = #expect(throws: XcdError.self) { try Runners.requireIOS(watch, name: "watch") }
        #expect(error?.code == .platformUnsupported)
        #expect(error?.next == "use an iPhone or iPad device from .xcdev.yml with `--device <name>`")
        let phone = ProvisionedDevice(udid: "P", deviceType: "iPhone 18 Pro", deviceTypeIdentifier: "t", runtime: "iOS 27.0",
                                      runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        #expect(throws: Never.self) { try Runners.requireIOS(phone, name: "iphone") }
    }

    @Test func stoppingUsesSIGTERMAndRemovesTheRecordAndReadyFile() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: Self.writesReady)
        var (supervisor, ctx) = try setup(detached: detached)
        _ = try await supervisor.session(device: nil, in: &ctx)
        let notes = try await supervisor.stop(device: nil, in: ctx)
        #expect(notes == ["stopped the iphone UI runner"])
        #expect(detached.stops.map(\.signal) == [SIGTERM])
        #expect(Runners.load(ctx.paths.runnerFile(device: "iphone")) == nil)
        #expect(!FileManager.default.fileExists(atPath: ctx.paths.runnerReadyFile(device: "iphone")))
        #expect(try await supervisor.stop(device: nil, in: ctx).isEmpty)
    }
}
