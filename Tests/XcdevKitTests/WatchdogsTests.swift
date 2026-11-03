import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct WatchdogsTests {
    let t0 = Date(timeIntervalSince1970: 1_791_100_000)
    let home = NSTemporaryDirectory() + "watchdogs-\(UUID().uuidString)"
    let detached = FakeDetachedProcesses()
    let holds = LeaseHolds()
    var leases: DeviceLeases { DeviceLeases(globalPaths: GlobalPaths(base: home), holds: holds) }
    var watchdogs: Watchdogs {
        let t0 = t0
        return Watchdogs(leases: leases, detached: detached, now: { t0 })
    }

    @Test func aWatchdogStartsDetachedWithTheCommandsHome() async throws {
        defer { Disk.remove(home) }
        try await watchdogs.start("U1", developerDir: "/X.app/Contents/Developer", log: "/w/.xcdev/logs/w.log",
                                  executable: "/usr/local/bin/xcd")
        let start = try #require(detached.starts.first)
        #expect(start.invocation.executable == "/usr/local/bin/xcd")
        #expect(start.invocation.arguments == ["_watch-device", "U1", "--developer-dir", "/X.app/Contents/Developer"])
        #expect(start.invocation.environment["XCDEV_HOME"] == home)
        #expect(start.invocation.workingDirectory == "/")                         // never keeps a worktree's volume busy
        #expect(start.log == "/w/.xcdev/logs/w.log")
        #expect(watchdogs.record("U1")?.process == start.identity)
        #expect(watchdogs.record("U1")?.startedAt == t0 && watchdogs.record("U1")?.udid == "U1")
        #expect(watchdogs.isLive("U1"))
    }

    @Test func aLiveWatchdogIsNotStartedTwice() async throws {
        defer { Disk.remove(home) }
        try await watchdogs.start("U1", developerDir: nil, log: "/l", executable: "/xcd")
        try await watchdogs.start("U1", developerDir: nil, log: "/l", executable: "/xcd")
        #expect(detached.starts.count == 1)
        #expect(detached.starts[0].invocation.arguments == ["_watch-device", "U1"])
    }

    /// A start that takes a while (as a real spawn does) leaves the second command time to look before the record is
    /// written: only `start.lock` keeps it from starting a second watchdog.
    @Test func twoStartsAtOnceStartOneWatchdog() async throws {
        defer { Disk.remove(home) }
        let slow = FakeDetachedProcesses(onStart: { _, _ in usleep(100_000) })
        let watchdogs = Watchdogs(leases: leases, detached: slow)
        async let one: Void = watchdogs.start("U1", developerDir: nil, log: "/l", executable: "/xcd")
        async let two: Void = watchdogs.start("U1", developerDir: nil, log: "/l", executable: "/xcd")
        _ = try await (one, two)
        #expect(slow.starts.count == 1)
    }

    /// A record naming a process that is not a watchdog (a reused pid) is not a live watchdog.
    @Test func aRecordOfAnotherProcessIsNotLive() async throws {
        defer { Disk.remove(home) }
        try await watchdogs.start("U1", developerDir: nil, log: "/l", executable: "/xcd")
        let pid = detached.starts[0].identity.pid
        detached.exit(pid: pid)
        detached.adopt(ProcessIdentity(pid: pid, startTime: detached.starts[0].identity.startTime, arguments: ["/bin/sleep", "60"]))
        #expect(!watchdogs.isLive("U1"))
        #expect(!watchdogs.isLive("U2"))                                          // no record at all
    }

    /// A watchdog no later command could find is never left running.
    @Test func aWatchdogWhoseRecordCannotBeWrittenIsStoppedAgain() async throws {
        defer { Disk.remove(home) }
        try Disk.makeFolder(leases.files("U1").watchdog + "/in-the-way")           // a folder where the record goes
        await #expect(throws: (any Error).self) {
            try await watchdogs.start("U1", developerDir: nil, log: "/l", executable: "/xcd")
        }
        #expect(detached.stops.map(\.pid) == detached.starts.map(\.identity.pid) && detached.stops.count == 1)
    }

    @Test func endingAWatchdogStopsItAndForgetsTheSession() async throws {
        defer { Disk.remove(home) }
        try leases.save(.sample(udid: "U1", renewedAt: t0, idle: 600))
        try await watchdogs.start("U1", developerDir: nil, log: "/l", executable: "/xcd")
        let pid = detached.starts[0].identity.pid
        await watchdogs.end("U1")
        #expect(detached.stops.map(\.pid) == [pid])
        #expect(detached.stops.map(\.signal) == [SIGTERM])
        #expect(watchdogs.record("U1") == nil)
        #expect(leases.load("U1") == nil)
        #expect(leases.holds.isHolding("U1"))
        leases.holds.release("U1")
    }
}
