import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct RunnerSupervisorTests {
    let worktree = FakeWorktree(prefix: "xcd supervisor")
    static let now = Date(timeIntervalSince1970: 1_791_100_000)
    static let yaml = """
    version: 1
    project: App.xcodeproj
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro" }
    """

    /// Writes the ready file as the real runner would, taking the path from the invocation's environment. It makes no
    /// folder for it: the supervisor must have created that before the launch.
    static let writesReady: @Sendable (Invocation, String) throws -> Void = { invocation, log in
        try FileManager.default.createDirectory(atPath: (log as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let ready = invocation.environment["TEST_RUNNER_XCD_READY_FILE"]!
        try #"{"port": 51234}"#.write(toFile: ready, atomically: true, encoding: .utf8)
    }

    func setup(detached: FakeDetachedProcesses = FakeDetachedProcesses(onStart: writesReady),
               transport: FakeRunnerTransport = FakeRunnerTransport(), now: Date = now,
               sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in _ = duration }) throws -> (RunnerSupervisor, WorktreeContext) {
        _ = try FakeSimulators(runner: worktree.runner, catalogJSON: Fixture.string("simctl-list.json"), devicesDirectory: worktree.root + "/sims")
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

    /// Boots the clone before the command under test runs. `age` is how long ago its device folder was created; nil
    /// leaves the clone without a readable folder.
    func bootClone(age: TimeInterval?, in ctx: inout WorktreeContext) async throws {
        let udid = try await worktree.provisioner.boot("iphone", in: &ctx).device.udid
        guard let age else { return }
        let folder = worktree.root + "/sims/" + udid
        try FileManager.default.createDirectory(atPath: folder + "/data", withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: Self.now.addingTimeInterval(-age)], ofItemAtPath: folder)
    }

    /// The timeout named by the error of a start that never becomes ready.
    func startTimeoutText(_ supervisor: RunnerSupervisor, _ ctx: inout WorktreeContext) async -> String? {
        var copy = ctx
        let error = await #expect(throws: XcdError.self) { _ = try await supervisor.session(device: nil, in: &copy) }
        ctx = copy
        return error?.message.components(separatedBy: "did not start within ").last
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
        // The simulator writes the ready file, so it lives in xcd's cache, never in the worktree (which may be under Documents).
        let ready = worktree.root + "/home/cache/ui-runner/ready/\(session.udid).json"
        #expect(start.invocation.environment["TEST_RUNNER_XCD_READY_FILE"] == ready && FileManager.default.fileExists(atPath: ready))
        let record = try #require(Runners.load(ctx.paths.runnerFile(device: "iphone")))
        #expect(record.port == 51234 && record.process == start.identity && record.udid == session.udid && !record.failed)
        #expect(record.runnerKey == "27A266a-" + RunnerSource.hash && record.readyFile == ready)
        #expect(try FileManager.default.contentsOfDirectory(atPath: ctx.paths.stateDirectory).filter { $0.contains("ready") }.isEmpty)
    }

    /// The record holds the bearer token.
    @Test func theRecordIsReadableOnlyByItsOwner() async throws {
        defer { worktree.remove() }
        var (supervisor, ctx) = try setup()
        _ = try await supervisor.session(device: nil, in: &ctx)
        let file = ctx.paths.runnerFile(device: "iphone")
        func mode() throws -> Int? { (try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue }
        #expect(try mode() == 0o600)
        try Runners.save(try #require(Runners.load(file)), to: file)                    // saved over an existing record
        #expect(try mode() == 0o600)
    }

    /// The record is created with its final mode and moved into place, so no other user can ever read the token.
    @Test func aRecordSavedOverAReadableFileIsPrivateAndLeavesNothingBehind() throws {
        defer { worktree.remove() }
        let folder = worktree.root + "/state"
        let file = folder + "/ui-runner-iphone.json"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: file, contents: Data("old".utf8), attributes: [.posixPermissions: 0o644]))
        let record = RunnerRecord(device: "iphone", udid: "U", process: ProcessIdentity(pid: 7, startTime: 1, arguments: ["xcodebuild"]),
                                  token: "secret", port: 40000, runnerKey: "k", log: "/l", readyFile: "/r",
                                  startedAt: Date(timeIntervalSince1970: 0), restarts: [], failed: false)
        try Runners.save(record, to: file)
        #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(Runners.load(file) == record && record.endpoint == RunnerEndpoint(port: 40000, token: "secret"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == ["ui-runner-iphone.json"])
        // A folder that can't be written to is an error, not a silent loss.
        #expect(throws: (any Error).self) { try Runners.save(record, to: "/dev/null/nope/ui-runner-iphone.json") }
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
        #expect(error?.message.contains("did not start within 10m00s") == true)     // a clone this command booted: first boot allowance
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

    @Test func aCloneThisCommandBootedGetsTheLongTimeout() async throws {
        #expect(RunnerSupervisor.startTimeout(warm: true) == .seconds(120))
        #expect(RunnerSupervisor.startTimeout(warm: false) == .seconds(600))
        defer { worktree.remove() }
        var (supervisor, ctx) = try setup(detached: FakeDetachedProcesses())            // never ready
        #expect(await startTimeoutText(supervisor, &ctx) == "10m00s")
    }

    @Test func aBootedCloneWithAnOldDeviceFolderGetsTheShortTimeout() async throws {
        defer { worktree.remove() }
        var (supervisor, ctx) = try setup(detached: FakeDetachedProcesses())            // never ready
        try await bootClone(age: 16 * 60, in: &ctx)
        #expect(await startTimeoutText(supervisor, &ctx) == "2m00s")
    }

    /// `xcd run` boots a new clone before the first `xcd ui`, so "already booted" alone doesn't mean it has settled.
    @Test func aBootedCloneWithAFreshDeviceFolderGetsTheLongTimeout() async throws {
        defer { worktree.remove() }
        var (supervisor, ctx) = try setup(detached: FakeDetachedProcesses())            // never ready
        try await bootClone(age: 14 * 60, in: &ctx)
        #expect(await startTimeoutText(supervisor, &ctx) == "10m00s")
    }

    @Test func aBootedCloneWhoseCreationDateCannotBeReadGetsTheLongTimeout() async throws {
        defer { worktree.remove() }
        var (supervisor, ctx) = try setup(detached: FakeDetachedProcesses())            // never ready
        try await bootClone(age: nil, in: &ctx)
        #expect(await startTimeoutText(supervisor, &ctx) == "10m00s")
    }

    @Test func aWatchIsRejectedBeforeItIsBooted() async throws {
        defer { worktree.remove() }
        let (supervisor, _) = try setup()
        var ctx = try worktree.context(Self.yaml + "\n  watch: { type: \"Apple Watch Series 11 (46mm)\", pairWith: iphone }")
        let error = await #expect(throws: XcdError.self) { _ = try await supervisor.session(device: "watch", in: &ctx) }
        #expect(error?.code == .platformUnsupported)
        #expect(!worktree.runner.commandLines.contains { $0.contains("simctl boot") })
    }

    @Test func stoppingAnOldRecordLeavesANewerRunnersFilesAlone() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: Self.writesReady)
        let (supervisor, ctx) = try setup(detached: detached)
        let file = ctx.paths.runnerFile(device: "iphone")
        let ready = supervisor.globalPaths.runnerReadyFile(udid: "U")
        func record(pid: Int32) -> RunnerRecord {
            RunnerRecord(device: "iphone", udid: "U", process: ProcessIdentity(pid: pid, startTime: 1, arguments: ["xcodebuild", Runners.marker]),
                         token: "t", port: 1, runnerKey: "k", log: "/l", readyFile: ready, startedAt: Date(timeIntervalSince1970: 0),
                         restarts: [], failed: false)
        }
        let newer = record(pid: 2)
        try Runners.save(newer, to: file)
        try FileManager.default.createDirectory(atPath: (ready as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "{}".write(toFile: ready, atomically: true, encoding: .utf8)
        await Runners.stop(record(pid: 1), file: file, detached: detached)             // an older record, loaded before the restart
        #expect(Runners.load(file) == newer && FileManager.default.fileExists(atPath: ready))
        await Runners.stop(newer, file: file, detached: detached)
        #expect(Runners.load(file) == nil && !FileManager.default.fileExists(atPath: ready))
    }

    @Test func stoppingAStaleRecordSaysSoInsteadOfClaimingToHaveStoppedIt() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: Self.writesReady)
        let (supervisor, ctx) = try setup(detached: detached)
        let stale = RunnerRecord(device: "iphone", udid: "U", process: ProcessIdentity(pid: 9, startTime: 1, arguments: ["xcodebuild", Runners.marker]),
                                 token: "t", port: 1, runnerKey: "k", log: "/l", readyFile: "/r", startedAt: Date(timeIntervalSince1970: 0),
                                 restarts: [], failed: false)
        try Runners.save(stale, to: ctx.paths.runnerFile(device: "iphone"))
        let notes = try await supervisor.stop(device: nil, in: ctx)
        #expect(notes == ["removed the stale iphone UI runner record"] && detached.stops.isEmpty)
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

    /// XCTest in this Xcode is built for iOS 17, so the runner would not load on an older runtime.
    @Test func anIOSRuntimeOlderThan17CannotBeDriven() {
        func phone(_ runtime: String, _ identifier: String) -> ProvisionedDevice {
            ProvisionedDevice(udid: "P", deviceType: "iPhone 15", deviceTypeIdentifier: "t", runtime: runtime,
                              runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime." + identifier)
        }
        let error = #expect(throws: XcdError.self) { try Runners.requireIOS(phone("iOS 16.4", "iOS-16-4"), name: "old") }
        #expect(error?.code == .platformUnsupported && error?.message == "the UI runner needs iOS 17 or later; 'old' runs iOS 16.4")
        #expect(error?.next == "give 'old' an iOS 17 or later runtime in .xcdev.yml, or pick another device with `--device <name>`")
        #expect(throws: XcdError.self) { try Runners.requireIOS(phone("iOS 15.0", "iOS-15-0"), name: "older") }
        #expect(throws: Never.self) { try Runners.requireIOS(phone("iOS 17.0", "iOS-17-0"), name: "lowest") }
        #expect(throws: Never.self) { try Runners.requireIOS(phone("iOS 18.2", "iOS-18-2"), name: "newer") }
        // A version xcd can't read is not refused: the runner's own start reports what goes wrong.
        #expect(throws: Never.self) { try Runners.requireIOS(phone("iOS", "iOS-beta"), name: "odd") }
    }

    @Test func stoppingUsesSIGTERMAndRemovesTheRecordAndReadyFile() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: Self.writesReady)
        var (supervisor, ctx) = try setup(detached: detached)
        let session = try await supervisor.session(device: nil, in: &ctx)
        let ready = supervisor.globalPaths.runnerReadyFile(udid: session.udid)
        #expect(FileManager.default.fileExists(atPath: ready))
        let notes = try await supervisor.stop(device: nil, in: ctx)
        #expect(notes == ["stopped the iphone UI runner"])
        #expect(detached.stops.map(\.signal) == [SIGTERM])
        #expect(Runners.load(ctx.paths.runnerFile(device: "iphone")) == nil)
        #expect(!FileManager.default.fileExists(atPath: ready))
        #expect(try await supervisor.stop(device: nil, in: ctx).isEmpty)
    }
}
