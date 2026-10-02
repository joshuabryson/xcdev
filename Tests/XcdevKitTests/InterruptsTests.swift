import Foundation
import Synchronization
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// None of these change the process's real signal dispositions; those that do are in `SignalDispositionTests`.
@Suite struct InterruptsTests {
    /// Process groups that exist only in this test: `send` signals them, never a real process. Pids are above macOS's
    /// largest (99998), so nothing real could match one.
    final class FakeGroups: Sendable {
        private let state = Mutex<(alive: Set<pid_t>, obeys: [pid_t: Set<Int32>], sent: [String])>(([], [:], []))

        /// A group led by `pid` that ends on any of `obeys`; SIGKILL always ends it.
        func add(_ pid: pid_t, obeys: Set<Int32>) {
            state.withLock { $0.alive.insert(pid); $0.obeys[pid] = obeys.union([SIGKILL]) }
        }

        /// Every signal sent, as "<target> <signal>", leaving out the liveness checks (signal 0).
        var sent: [String] { state.withLock { $0.sent } }

        func send(_ target: pid_t, _ signal: Int32) -> Int32 {
            state.withLock { state in
                let pid = abs(target)
                guard state.alive.contains(pid) else { errno = ESRCH; return -1 }
                guard signal != 0 else { return 0 }
                state.sent.append("\(target) \(signal)")
                if state.obeys[pid]?.contains(signal) == true { state.alive.remove(pid) }
                return 0
            }
        }
    }

    final class Lines: Sendable {
        private let lines = Mutex<[String]>([])
        func add(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    /// Interrupts over `groups`, with sleeps that only count.
    func interrupts(_ groups: FakeGroups, report: Lines = Lines(), slept: Counter = Counter()) -> Interrupts {
        Interrupts(report: report.add, send: groups.send, sleep: { _ in slept.increment() })
    }

    static var discard: ChildProcess.Stdio {
        .redirected(output: FileHandle.nullDevice.fileDescriptor, error: FileHandle.nullDevice.fileDescriptor)
    }

    func track(_ interrupts: Interrupts, _ pid: pid_t, _ argv: [String], foreground: Bool = false) throws -> ChildProcess {
        try interrupts.launch(argv, foreground: foreground) { ChildProcess(pid: pid, leadsGroup: !foreground) }
    }

    // MARK: Signalling only children xcd still owns

    @Test func aChildThatLeadsAGroupIsSignalledThroughItsGroup() {
        let groups = FakeGroups()
        groups.add(100_001, obeys: [])
        groups.add(100_002, obeys: [])
        #expect(ChildProcess(pid: 100_001, leadsGroup: true).signal(SIGINT, using: groups.send))
        #expect(ChildProcess(pid: 100_002, leadsGroup: false).signal(SIGINT, using: groups.send))   // passthrough: xcd's group
        #expect(groups.sent == ["-100001 2", "100002 2"])
    }

    @Test func aReapedChildIsNeverSignalled() {
        let groups = FakeGroups()
        groups.add(100_003, obeys: [])
        let child = ChildProcess(pid: 100_003, leadsGroup: true)
        child.exited(reap: true)                                             // its pid may now belong to anyone
        #expect(!child.signal(SIGKILL, using: groups.send))
        #expect(groups.sent.isEmpty)
    }

    /// Kept as a zombie (once interrupted), the child's pid and group can't be reused, so its group can still be stopped.
    @Test func anUnreapedChildsGroupCanStillBeSignalled() {
        let groups = FakeGroups()
        groups.add(100_004, obeys: [])
        let child = ChildProcess(pid: 100_004, leadsGroup: true)
        child.exited(reap: false)
        #expect(child.signal(SIGTERM, using: groups.send))
        #expect(groups.sent == ["-100004 15"])
    }

    /// A real child: once it has exited and been reaped, it is out of reach.
    @Test func aRealChildIsReapedWhenItExitsAndThenOutOfReach() async throws {
        let child = try ChildProcess.spawn("/bin/sh", arguments: ["-c", "exit 3"], environment: [:], workingDirectory: nil,
                                           stdio: Self.discard, leadsGroup: true)
        child.watch(keepZombie: { false })
        #expect(await child.wait() == 3)
        let sent = Counter()
        #expect(!child.signal(SIGTERM, using: { _, _ in sent.increment(); return 0 }))
        #expect(sent.value == 0)
    }

    @Test func aChildKilledByASignalReports128PlusTheSignal() async throws {
        let child = try ChildProcess.spawn("/bin/sh", arguments: ["-c", "kill -TERM $$"], environment: [:],
                                           workingDirectory: nil, stdio: Self.discard, leadsGroup: true)
        child.watch(keepZombie: { false })
        #expect(await child.wait() == 143)
    }

    // MARK: The handler

    @Test func ctrlCStopsEachGroupEscalatingFromSIGINTToSIGTERMToSIGKILL() throws {
        let groups = FakeGroups()
        groups.add(100_011, obeys: [SIGINT])                                 // xcodebuild: SIGINT is a clean cancel
        groups.add(100_012, obeys: [SIGTERM])
        groups.add(100_013, obeys: [])                                       // ignores both
        let report = Lines()
        let slept = Counter()
        let interrupts = interrupts(groups, report: report, slept: slept)
        _ = try track(interrupts, 100_011, ["xcrun", "xcodebuild", "build"])
        _ = try track(interrupts, 100_012, ["xcrun", "simctl", "boot"])
        _ = try track(interrupts, 100_013, ["sh", "-c", "trap '' INT TERM; sleep 9"])
        #expect(interrupts.handle(SIGINT) == 130)
        #expect(groups.sent == ["-100011 2", "-100012 2", "-100013 2", "-100012 15", "-100013 15", "-100013 9"])
        #expect(report.all == ["interrupted; stopped xcodebuild, simctl, sh"])
        #expect(slept.value > 0 && slept.value <= 3 * 20 + 20 + 20)          // bounded: the grace, then a second each
    }

    @Test func sigtermExits143AndAGroupThatEndsOnSIGINTIsNotSignalledAgain() throws {
        let groups = FakeGroups()
        groups.add(100_021, obeys: [SIGINT])
        let slept = Counter()
        let interrupts = interrupts(groups, slept: slept)
        _ = try track(interrupts, 100_021, ["xcrun", "xcodebuild", "test"])
        #expect(interrupts.handle(SIGTERM) == 143)
        #expect(groups.sent == ["-100021 2"])
        #expect(slept.value == 0)                                            // it was gone at the first check
    }

    /// SIGHUP (the terminal closed) stops the children the same way and exits 129.
    @Test func sighupStopsTheChildrenAndExits129() throws {
        let groups = FakeGroups()
        groups.add(100_022, obeys: [SIGINT])
        let report = Lines()
        let interrupts = interrupts(groups, report: report)
        _ = try track(interrupts, 100_022, ["xcrun", "xcodebuild", "build"])
        #expect(interrupts.handle(SIGHUP) == 129)
        #expect(groups.sent == ["-100022 2"])
        #expect(report.all == ["interrupted; stopped xcodebuild"])
    }

    /// A write that never finishes (stdout is a pipe nobody reads) must not keep the handler from stopping the
    /// children and exiting: writes happen outside the lock, and the handler waits for them only briefly.
    @Test func aBlockedWriteDoesntStopTheHandler() throws {
        let groups = FakeGroups()
        groups.add(100_023, obeys: [SIGINT])
        let report = Lines()
        let interrupts = interrupts(groups, report: report)
        _ = try track(interrupts, 100_023, ["xcrun", "xcodebuild", "build"])
        let writing = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        Thread.detachNewThread { interrupts.perform { writing.signal(); release.wait() } }
        writing.wait()
        let code = Mutex<Int32?>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let result = interrupts.handle(SIGTERM)
            code.withLock { $0 = result }
            done.signal()
        }
        let finished = done.wait(timeout: .now() + 20) == .success     // generous: the machine may be busy
        release.signal()
        if !finished { done.wait() }
        #expect(finished)
        #expect(code.withLock { $0 } == 143)
        #expect(groups.sent == ["-100023 2"])
        #expect(report.all == ["interrupted; stopped xcodebuild"])
        #expect(!interrupts.perform { })                                     // and no new write starts
    }

    @Test func cleanupsRunNewestFirstAndOnlyWhileRegistered() {
        let order = Lines()
        let report = Lines()
        let interrupts = interrupts(FakeGroups(), report: report)
        _ = interrupts.addCleanup { order.add("scratch") }
        let removed = interrupts.addCleanup { order.add("removed") }
        _ = interrupts.addCleanup { order.add("line") }
        interrupts.removeCleanup(removed)
        #expect(interrupts.handle(SIGINT) == 130)
        #expect(order.all == ["line", "scratch"])
        #expect(report.all == ["interrupted"])                               // nothing was running
    }

    /// Each instance has its own cleanups, so a test's interrupt can't remove another test's folders.
    @Test func instancesDontShareCleanups() {
        let ran = Counter()
        let other = interrupts(FakeGroups())
        _ = other.addCleanup { ran.increment() }
        #expect(interrupts(FakeGroups()).handle(SIGINT) == 130)
        #expect(ran.value == 0 && !other.fired)
    }

    @Test func afterAnInterruptNothingIsWrittenAndNothingNewStarts() async throws {
        let interrupts = interrupts(FakeGroups())
        #expect(interrupts.perform { })
        #expect(interrupts.handle(SIGINT) == 130)
        #expect(interrupts.fired)
        let wrote = Counter()
        #expect(!interrupts.perform { wrote.increment() })
        let blocked = Task { await interrupts.output { wrote.increment() } }   // waits for the handler to exit xcd
        try await Task.sleep(for: .milliseconds(100))
        blocked.cancel()
        await blocked.value
        #expect(wrote.value == 0)
        #expect(throws: XcdError.self) { try track(interrupts, 100_031, ["git"]) }
    }

    // MARK: Passthrough children own Ctrl-C

    @Test func whileAPassthroughChildRunsCtrlCIsItsAndSIGTERMIsPassedOn() throws {
        let groups = FakeGroups()
        groups.add(100_041, obeys: [SIGTERM])
        let ran = Counter()
        let interrupts = interrupts(groups)
        _ = interrupts.addCleanup { ran.increment() }
        let child = try track(interrupts, 100_041, ["xcd-asker"], foreground: true)
        #expect(interrupts.handle(SIGINT) == nil)                            // the terminal sent it to the child too
        #expect(interrupts.handle(SIGTERM) == nil)
        #expect(groups.sent == ["100041 15"])                                // to the child alone: its group is xcd's
        #expect(!interrupts.fired && ran.value == 0)
        interrupts.finished(child)
        #expect(interrupts.handle(SIGINT) == 130)
        #expect(ran.value == 1)
    }
}
