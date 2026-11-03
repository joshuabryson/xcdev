import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// A worktree whose `iphone` clone is booted (made outside any provisioner), and the idle sessions of `<root>/home`.
@Suite struct IdleSessionsTests {
    static let yaml = """
    version: 1
    project: App.xcodeproj
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro" }
    """
    let t0 = Date(timeIntervalSince1970: 1_791_100_000)
    let worktree = FakeWorktree(prefix: "xcd idle")
    let clock = Shared(Date(timeIntervalSince1970: 1_791_100_000))
    let holds = LeaseHolds()
    let detached = FakeDetachedProcesses()
    let simulators: FakeSimulators
    let device: ProvisionedDevice
    let ctx: WorktreeContext
    var home: String { worktree.root + "/home" }
    var leases: DeviceLeases { DeviceLeases(globalPaths: GlobalPaths(base: home), holds: holds) }
    var simctl: SimctlClient { SimctlClient(runner: worktree.runner, developerDir: ctx.xcode?.developerDir) }
    var sessions: IdleSessions { sessions(detached) }
    var provisioner: DeviceProvisioner {
        DeviceProvisioner(runner: worktree.runner, globalPaths: GlobalPaths(base: home), sessions: sessions)
    }

    init() throws {
        simulators = try FakeSimulators(runner: worktree.runner, catalogJSON: Fixture.string("simctl-list.json"))
        let udid = simulators.add(name: "xcd · App · feat · iphone", state: "Booted")
        device = ProvisionedDevice(udid: udid, deviceType: "iPhone 18 Pro",
                                   deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
                                   runtime: "iOS 27.0", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        var ctx = try worktree.context(Self.yaml)
        ctx.state.devices["iphone"] = device
        self.ctx = ctx
    }

    func sessions(_ detached: FakeDetachedProcesses) -> IdleSessions {
        let clock = clock
        return IdleSessions(leases: leases, detached: detached, executable: "/xcd", now: { clock.value })
    }

    func cleanUp() {
        holds.release(device.udid)
        worktree.remove()
    }

    @Test func aNewSessionWritesALeaseHoldsItAndStartsAWatchdog() async throws {
        defer { cleanUp() }
        #expect(await sessions.began("iphone", device, in: ctx, simctl: simctl) == nil)
        let lease = try #require(leases.load(device.udid))
        #expect(lease.bootedAt == t0 && lease.renewedAt == t0 && lease.idle == 600)
        #expect(lease.device == "iphone" && lease.worktree == ctx.state.name && lease.worktreeRoot == ctx.location.worktreeRoot)
        #expect(lease.project == "App" && lease.udid == device.udid)
        #expect(lease.developerDir == ctx.xcode?.developerDir)
        #expect(leases.holds.isHolding(device.udid))
        let start = try #require(detached.starts.first)
        #expect(start.log.hasPrefix(ctx.paths.logs + "/") && start.log.hasSuffix("-watchdog-iphone.log"))
        #expect(start.invocation.executable == "/xcd")
        #expect(start.invocation.arguments == ["_watch-device", device.udid, "--developer-dir", "/Applications/Xcode.app/Contents/Developer"])
        #expect(sessions.watchdogs.isLive(device.udid))
    }

    @Test func aRunningSessionKeepsItsLeaseAndWatchdog() async throws {
        defer { cleanUp() }
        _ = await sessions.began("iphone", device, in: ctx, simctl: simctl)
        holds.release(device.udid)
        clock.set(t0 + 300)
        _ = await sessions.began("iphone", device, in: ctx, simctl: simctl)
        #expect(detached.starts.count == 1)
        #expect(leases.load(device.udid)?.bootedAt == t0)
        #expect(holds.isHolding(device.udid))                                     // held again for this command
    }

    @Test func theIdleFlagReplacesARunningSessionsThreshold() async throws {
        defer { cleanUp() }
        _ = await sessions.began("iphone", device, in: ctx, simctl: simctl)
        var flagged = ctx; flagged.idleOverride = 60
        _ = await sessions.began("iphone", device, in: flagged, simctl: simctl)
        #expect(leases.load(device.udid)?.idle == 60)
        #expect(leases.load(device.udid)?.bootedAt == t0)
    }

    @Test func theIdleFlagSetsANewSessionsThreshold() async throws {
        defer { cleanUp() }
        var flagged = ctx; flagged.idleOverride = 0
        _ = await sessions.began("iphone", device, in: flagged, simctl: simctl)
        #expect(leases.load(device.udid)?.idle == 0)
    }

    @Test func aSessionWhoseWatchdogDiedStartsAgain() async throws {
        defer { cleanUp() }
        _ = await sessions.began("iphone", device, in: ctx, simctl: simctl)
        detached.exit(pid: detached.starts[0].identity.pid)
        clock.set(t0 + 300)
        _ = await sessions.began("iphone", device, in: ctx, simctl: simctl)
        #expect(detached.starts.count == 2)
        #expect(leases.load(device.udid)?.bootedAt == t0 + 300)
    }

    @Test func anUnreadableLeaseIsReplacedByANewSession() async throws {
        defer { cleanUp() }
        try Disk.makeFolder(leases.files(device.udid).folder)
        try Data("{".utf8).write(to: URL(fileURLWithPath: leases.files(device.udid).lease))
        _ = await sessions.began("iphone", device, in: ctx, simctl: simctl)
        #expect(leases.load(device.udid)?.bootedAt == t0)
    }

    @Test func aWatchdogThatCannotStartBecomesANote() async throws {
        defer { cleanUp() }
        let failing = sessions(FakeDetachedProcesses(onStart: { _, _ in
            throw XcdError(.subprocessFailed, "xcd exited as soon as it started")
        }))
        #expect(await failing.began("iphone", device, in: ctx, simctl: simctl)
                == "could not start the idle watchdog: xcd exited as soon as it started; the clone stays booted until xcd sim shutdown")
        #expect(leases.load(device.udid) != nil)
    }

    @Test func aLeaseThatCannotBeSavedBecomesTheSameNote() async throws {
        defer { cleanUp() }
        try Disk.makeFolder(home)
        try Data().write(to: URL(fileURLWithPath: GlobalPaths(base: home).devicesDirectory))     // a file where the folder goes
        let note = try #require(await sessions.began("iphone", device, in: ctx, simctl: simctl))
        #expect(note.hasPrefix("could not start the idle watchdog: ") && note.hasSuffix("; the clone stays booted until xcd sim shutdown"))
        #expect(detached.starts.isEmpty)
    }

    @Test func housekeepingRemovesOnlyDeadSessions() async throws {
        let off = simulators.add(name: "off")
        let watched = simulators.add(name: "watched")
        let held = simulators.add(name: "held")
        defer { cleanUp() }
        for udid in ["GONE", off, watched, held] { try leases.save(.sample(udid: udid)) }
        try await sessions.watchdogs.start(watched, developerDir: nil, log: "/l", executable: "/xcd")
        let hold = try await FileLock.hold(at: leases.files(held).lock)
        defer { FileLock.release(hold) }
        _ = await sessions.began("iphone", device, in: ctx, simctl: simctl)
        #expect(!Disk.exists(leases.files("GONE").folder))
        #expect(!Disk.exists(leases.files(off).folder))
        #expect(Disk.exists(leases.files(watched).folder))
        #expect(Disk.exists(leases.files(held).folder))
        #expect(leases.load(device.udid) != nil)
    }

    /// Another command's sweep may work from a `simctl list` read before this boot, and it skips only a held folder. So
    /// a new session holds the lock before its lease exists: while an exclusive holder (as a watchdog shutting down)
    /// has the lock, `began` waits with no lease written.
    @Test func aNewSessionHoldsTheLockBeforeItWritesTheLease() async throws {
        defer { cleanUp() }
        let files = leases.files(device.udid)
        try Disk.makeFolder(files.folder)
        let exclusive = open(files.lock, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        #expect(exclusive >= 0 && flock(exclusive, LOCK_EX) == 0)
        let began = Task { [sessions, device, ctx, simctl] in await sessions.began("iphone", device, in: ctx, simctl: simctl) }
        while !worktree.runner.calls.contains(where: { $0.arguments.starts(with: ["simctl", "list"]) }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))                            // past the sweep, to the hold
        #expect(!Disk.exists(files.lease))
        flock(exclusive, LOCK_UN)
        close(exclusive)
        #expect(await began.value == nil)
        #expect(leases.load(device.udid) != nil && holds.isHolding(device.udid))
        // With the hold in place, a sweep that sees the clone shut down with no live watchdog keeps its folder.
        simulators.setState("Shutdown", udid: device.udid)
        leases.sweep(try await simctl.catalog(), isLive: { _ in false })
        #expect(Disk.exists(files.folder) && leases.load(device.udid) != nil)
    }

    /// The fast path reads no `simctl list`: only a new session sweeps.
    @Test func aRunningSessionSweepsNothing() async throws {
        defer { cleanUp() }
        _ = await sessions.began("iphone", device, in: ctx, simctl: simctl)
        try leases.save(.sample(udid: "GONE"))
        _ = await sessions.began("iphone", device, in: ctx, simctl: simctl)
        #expect(Disk.exists(leases.files("GONE").folder))
    }

    // MARK: The provisioner

    @Test func bootingLeasesTheClone() async throws {
        defer { cleanUp() }
        var fresh = try worktree.context(Self.yaml)
        let (booted, _) = try await provisioner.boot("iphone", in: &fresh)
        #expect(leases.load(booted.udid) != nil)
        #expect(detached.starts.count == 1)
        holds.release(booted.udid)
    }

    @Test func aProvisionerWithoutSessionsLeasesNothing() async throws {
        defer { cleanUp() }
        var fresh = try worktree.context(Self.yaml)
        _ = try await worktree.provisioner.boot("iphone", in: &fresh)
        #expect(!Disk.exists(GlobalPaths(base: home).devicesDirectory))
        #expect(detached.starts.isEmpty)
    }

    @Test func anIdleFlagIsNoted() async throws {
        defer { cleanUp() }
        let notes = Notes()
        var fresh = try worktree.context(Self.yaml)
        fresh.idleOverride = 60
        let booted = try await Notes.$current.withValue(notes) { try await provisioner.boot("iphone", in: &fresh) }.device
        #expect(notes.all.contains("idle 1m"))
        #expect(leases.load(booted.udid)?.idle == 60)
        holds.release(booted.udid)
    }

    @Test func aWatchdogThatCannotStartIsNotedAndTheBootSucceeds() async throws {
        defer { cleanUp() }
        let notes = Notes()
        let failing = DeviceProvisioner(runner: worktree.runner, globalPaths: GlobalPaths(base: home),
                                        sessions: sessions(FakeDetachedProcesses(onStart: { _, _ in
                                            throw XcdError(.subprocessFailed, "xcd exited as soon as it started")
                                        })))
        var fresh = try worktree.context(Self.yaml)
        let booted = try await Notes.$current.withValue(notes) { try await failing.boot("iphone", in: &fresh) }.device
        #expect(notes.all == ["could not start the idle watchdog: xcd exited as soon as it started; the clone stays booted until xcd sim shutdown"])
        holds.release(booted.udid)
    }

    @Test func leasingIfBootedLeasesOnlyABootedClone() async throws {
        defer { cleanUp() }
        simulators.setState("Shutdown", udid: device.udid)
        await provisioner.leaseIfBooted("iphone", in: ctx)
        #expect(leases.load(device.udid) == nil)
        simulators.setState("Booted", udid: device.udid)
        await provisioner.leaseIfBooted("iphone", in: ctx)
        #expect(leases.load(device.udid) != nil)
        await provisioner.leaseIfBooted("watch", in: ctx)                         // never cloned: nothing to lease
        #expect(detached.starts.count == 1)
    }
}
