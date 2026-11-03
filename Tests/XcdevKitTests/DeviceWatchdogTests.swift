import Darwin
import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The watchdog (pid 4242) of the clone `U1`, Booted in a fake `simctl list`, whose lease names a worktree folder that
/// exists. `stale` was last renewed 660 s before `t0` with an idle of 600 s.
@Suite struct DeviceWatchdogTests {
    static let catalog = """
    {"devicetypes": [], "runtimes": [], "devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
      {"udid": "U1", "name": "xcd · App · main · iphone", "state": "Booted", "isAvailable": true,
       "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"}]}}
    """
    let t0 = Date(timeIntervalSince1970: 1_791_100_000)
    let base = NSTemporaryDirectory() + "watchdog-\(UUID().uuidString)"
    let fake = FakeProcessRunner()
    let sims: FakeSimulators
    let detached = FakeDetachedProcesses()
    let holds = LeaseHolds()
    let clock = Shared(Date(timeIntervalSince1970: 1_791_100_000))
    let lines = Shared<[String]>([])
    var home: String { base + "/home" }
    var root: String { base + "/worktree" }
    var leases: DeviceLeases { DeviceLeases(globalPaths: GlobalPaths(base: home), holds: holds) }
    var simctl: SimctlClient { SimctlClient(runner: fake, developerDir: nil, sleep: Instant.sleep) }
    var stale: DeviceLease { .sample(udid: "U1", renewedAt: t0 - 660, idle: 600, root: root) }

    init() throws {
        sims = try FakeSimulators(runner: fake, catalogJSON: Self.catalog)
        try FileManager.default.createDirectory(atPath: base + "/worktree", withIntermediateDirectories: true)
    }

    func watchdog() -> DeviceWatchdog {
        let clock = clock, lines = lines
        return DeviceWatchdog(udid: "U1", leases: leases, simctl: simctl, detached: detached, ownPid: 4242,
                              now: { clock.value }, log: { line in lines.change { $0.append(line) } })
    }

    func state(_ udid: String) -> String? { sims.devices.first { $0.udid == udid }?.state }

    func writeRecord(pid: Int32) throws {
        let process = ProcessIdentity(pid: pid, startTime: 1, arguments: ["xcd", "_watch-device", "U1"])
        try Watchdogs(leases: leases, detached: detached).save(WatchdogRecord(process: process, udid: "U1", startedAt: t0, log: "/l"))
    }

    func record() -> WatchdogRecord? { Watchdogs(leases: leases, detached: detached).record("U1") }

    func cleanUp() { Disk.remove(base) }

    @Test func aFreshLeaseIsLeftAlone() async throws {
        defer { cleanUp() }
        try leases.save(.sample(udid: "U1", renewedAt: t0 - 60, idle: 600, root: root))
        var dog = watchdog()
        #expect(await dog.poll() == .wait)
        #expect(state("U1") == "Booted")
    }

    @Test func aHeldLeaseIsLeftAloneEvenWhenStale() async throws {
        defer { cleanUp() }
        try leases.save(stale)
        let fd = try await FileLock.hold(at: leases.files("U1").lock)
        defer { FileLock.release(fd) }
        var dog = watchdog()
        #expect(await dog.poll() == .wait)
        #expect(state("U1") == "Booted")
    }

    @Test func aStaleFreeLeaseShutsTheCloneDown() async throws {
        defer { cleanUp() }
        try leases.save(stale)
        try writeRecord(pid: 4242)
        var dog = watchdog()
        #expect(await dog.poll() == .exit(0))
        #expect(state("U1") == "Shutdown")
        #expect(leases.load("U1") == nil)
        #expect(record() == nil)
        #expect(lines.value.contains("shut down U1 after 660 s idle"))
    }

    /// A command waiting on its hold while the clone shuts down must find neither the lease nor the record once it gets
    /// through, so it begins a new session with a new watchdog: both go before the exclusive lock is let go.
    @Test func theSessionIsForgottenBeforeTheLockIsLetGo() async throws {
        defer { cleanUp() }
        try leases.save(stale)
        try writeRecord(pid: 4242)
        let clock = clock, files = leases.files("U1")
        let seen = Shared<[Bool]>([])
        var dog = DeviceWatchdog(udid: "U1", leases: leases, simctl: simctl, detached: detached, ownPid: 4242,
                                 now: { clock.value }, log: { line in
            guard line.hasPrefix("shut down") else { return }
            seen.set([FileLock.isHeld(at: files.lock), Disk.exists(files.lease), Disk.exists(files.watchdog)])
        })
        #expect(await dog.poll() == .exit(0))
        #expect(seen.value == [true, false, false])                             // held, no lease, no record
        #expect(!FileLock.isHeld(at: files.lock))
    }

    @Test func aStaleLeaseWithALiveRunnerIsShutDownAndTheRunnerStopped() async throws {
        defer { cleanUp() }
        try leases.save(stale)
        let runner = ProcessIdentity(pid: 7001, startTime: 1, arguments: ["xcodebuild", "test-without-building"])
        detached.adopt(runner)
        try Runners.save(RunnerRecord.sample(device: "iphone", udid: "U1", process: runner),
                         to: WorktreePaths(root: root).runnerFile(device: "iphone"))
        var dog = watchdog()
        #expect(await dog.poll() == .exit(0))
        #expect(detached.stops.contains { $0.pid == 7001 })
        #expect(state("U1") == "Shutdown")
        #expect(lines.value.contains("stopped the iphone UI runner"))
    }

    @Test func aStaleLeaseWithALiveRecordingIsShutDownAndTheRecordingStopped() async throws {
        defer { cleanUp() }
        try leases.save(stale)
        let recorder = ProcessIdentity(pid: 7002, startTime: 1, arguments: ["xcrun", "simctl", "io", "U1", "recordVideo", "/v.mp4"])
        detached.adopt(recorder)
        try Recordings.save(RecordingRecord.sample(device: "iphone", udid: "U1", process: recorder),
                            to: WorktreePaths(root: root).recordingFile(device: "iphone"))
        var dog = watchdog()
        #expect(await dog.poll() == .exit(0))
        #expect(detached.stops.contains { $0.pid == 7002 && $0.signal == SIGINT })
        #expect(state("U1") == "Shutdown")
    }

    @Test func aGoneLeaseEndsTheWatchdog() async throws {
        defer { cleanUp() }
        try writeRecord(pid: 4242)
        var dog = watchdog()
        #expect(await dog.poll() == .exit(0))
        #expect(record() == nil)
    }

    @Test func anExitingWatchdogLeavesAnotherWatchdogsRecord() async throws {
        defer { cleanUp() }
        try writeRecord(pid: 9999)
        var dog = watchdog()
        #expect(await dog.poll() == .exit(0))
        #expect(record()?.process.pid == 9999)
    }

    @Test func aCloneNoLongerBootedEndsTheWatchdog() async throws {
        defer { cleanUp() }
        try leases.save(stale)
        try writeRecord(pid: 4242)
        sims.setState("Shutdown", udid: "U1")
        var dog = watchdog()
        #expect(await dog.poll() == .exit(0))
        #expect(leases.load("U1") == nil)
        #expect(record() == nil)
        #expect(!fake.commandLines.contains { $0.contains("shutdown") })
    }

    @Test func aListThatFailsCountsAsBooted() async throws {
        defer { cleanUp() }
        try leases.save(.sample(udid: "U1", renewedAt: t0, idle: 600, root: root))
        fake.stub(["xcrun", "simctl", "list"], exitCode: 1, stderr: "CoreSimulatorService connection became invalid")
        var dog = watchdog()
        #expect(await dog.poll() == .wait)
        #expect(leases.load("U1") != nil)
        #expect(lines.value.first?.hasPrefix("simctl list failed: ") == true)
    }

    @Test func theListIsReadOncePerMinute() async throws {
        defer { cleanUp() }
        try leases.save(.sample(udid: "U1", renewedAt: t0, idle: 600, root: root))
        var dog = watchdog()
        _ = await dog.poll()
        clock.set(t0 + 5)
        _ = await dog.poll()
        clock.set(t0 + 65)
        _ = await dog.poll()
        #expect(fake.commandLines.filter { $0.contains("simctl list") }.count == 2)
    }

    @Test func aRenewalWhileTakingTheLockSkipsTheShutdown() async throws {
        defer { cleanUp() }
        try leases.save(.sample(udid: "U1", renewedAt: t0, idle: 600, root: root))   // renewed on disk
        var dog = watchdog()
        #expect(await dog.shutDown(stale) == .wait)
        #expect(state("U1") == "Booted")
        #expect(leases.load("U1") != nil)
    }

    @Test func aShutdownThatKeepsFailingGivesUpKeepingTheLease() async throws {
        defer { cleanUp() }
        try leases.save(stale)
        try writeRecord(pid: 4242)
        fake.stub(["xcrun", "simctl", "shutdown", "U1"], exitCode: 1, stderr: "boom")   // not transient: no client retry
        var dog = watchdog()
        #expect(await dog.poll() == .retry)
        #expect(await dog.poll() == .retry)
        #expect(await dog.poll() == .exit(1))
        #expect(lines.value.filter { $0.hasPrefix("shutdown failed: ") }.count == 3)
        #expect(lines.value.contains("  boom"))
        #expect(lines.value.last == "giving up")
        #expect(leases.load("U1") != nil)
        #expect(record() == nil)
    }

    @Test func aVanishedWorktreeIsStaleAtOnce() async throws {
        defer { cleanUp() }
        try leases.save(.sample(udid: "U1", renewedAt: t0, idle: 600, root: "/nonexistent/worktree"))
        var dog = watchdog()
        #expect(await dog.poll() == .exit(0))
        #expect(state("U1") == "Shutdown")
    }

    @Test func anIdleOfOffNeverShutsDown() async throws {
        defer { cleanUp() }
        try leases.save(.sample(udid: "U1", renewedAt: t0 - 86_400, idle: 0, root: root))
        var dog = watchdog()
        #expect(await dog.poll() == .wait)
        #expect(state("U1") == "Booted")
    }

    @Test func runSleepsBetweenPollsUntilItExits() async throws {
        defer { cleanUp() }
        try leases.save(.sample(udid: "U1", renewedAt: t0, idle: 600, root: root))
        let slept = Shared<[Duration]>([])
        let clock = clock, t0 = t0
        var dog = watchdog()
        let code = await dog.run { duration in
            slept.change { $0.append(duration) }
            clock.set(t0 + 700)
        }
        #expect(code == 0)
        #expect(slept.value == [.seconds(5)])
    }

    @Test func aFailedShutdownWaitsTheRetryInterval() async throws {
        defer { cleanUp() }
        try leases.save(stale)
        fake.stub(["xcrun", "simctl", "shutdown", "U1"], exitCode: 1, stderr: "boom")
        let slept = Shared<[Duration]>([])
        var dog = watchdog()
        let code = await dog.run { duration in slept.change { $0.append(duration) } }
        #expect(code == 1)
        #expect(slept.value == [.seconds(10), .seconds(10)])
    }
}

private extension RunnerRecord {
    static func sample(device: String, udid: String, process: ProcessIdentity) -> RunnerRecord {
        RunnerRecord(device: device, udid: udid, process: process, token: "token", port: 4100, runnerKey: "key", log: "/l",
                     readyFile: "/nonexistent/ready.json", startedAt: Date(timeIntervalSince1970: 1_791_100_000),
                     restarts: [], failed: false)
    }
}

private extension RecordingRecord {
    static func sample(device: String, udid: String, process: ProcessIdentity) -> RecordingRecord {
        RecordingRecord(device: device, udid: udid, path: "/nonexistent/v.mp4", log: "/l", process: process,
                        startedAt: Date(timeIntervalSince1970: 1_791_100_000))
    }
}
