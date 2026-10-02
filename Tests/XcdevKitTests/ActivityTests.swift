import Foundation
import Synchronization
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Serialized: tests that install SIGINT handlers would otherwise restore each other's dispositions out of order.
@Suite(.serialized) struct ActivityTests {
    /// Everything a reporter wrote, in order.
    final class Recorder: Sendable {
        private let writes = Mutex<[String]>([])
        func write(_ text: String) { writes.withLock { $0.append(text) } }
        var all: [String] { writes.withLock { $0 } }
    }

    /// A clock that moves one second each time it is read.
    final class SteppingClock: Sendable {
        private let reads = Mutex(0)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        func now() -> Date { reads.withLock { $0 += 1; return start.addingTimeInterval(TimeInterval($0 - 1)) } }
    }

    func animated(_ recorder: Recorder, clock: SteppingClock = SteppingClock()) -> Activity {
        .animated(write: recorder.write, now: clock.now, tick: { await Task.yield() }, catchesInterrupt: false)
    }

    /// Runs until the spinner has drawn at least `frames` frames, without sleeping.
    func waitForFrames(_ recorder: Recorder, _ frames: Int) async {
        while recorder.all.filter({ $0.hasPrefix("\r") && !$0.hasPrefix("\r\u{1B}[K") }).count < frames { await Task.yield() }
    }

    @Test func framesRedrawOneLineWithTheElapsedTime() {
        #expect(Activity.frame(2, message: "resolving Swift packages…", elapsed: 23.4)
                == "\r⠹ xcd: resolving Swift packages… 23s\u{1B}[K")
        #expect(Activity.frame(12, message: "m", elapsed: 0).hasPrefix("\r⠹ xcd: m 0s"))      // frames wrap
        #expect(Activity.frame(0, message: "m", elapsed: 125).hasSuffix(" 2m05s\u{1B}[K"))
        #expect(Activity.finished("resolved Swift packages", elapsed: 41.7) == "\r\u{1B}[Kxcd: resolved Swift packages (41s)\n")
        #expect(Activity.frames.count == 10)
    }

    @Test func aFrameIsShortenedToFitTheTerminalSoItNeverWraps() {
        let long = String(repeating: "x", count: 100)
        let frame = Activity.frame(0, message: long, elapsed: 23, columns: 40)
        #expect(frame == "\r⠋ xcd: " + String(repeating: "x", count: 27) + "… 23s\u{1B}[K")
        #expect(frame.dropFirst().dropLast(3).count == 39)                    // one column spare: no wrap at the edge
        #expect(Activity.frame(0, message: "short", elapsed: 1, columns: 40) == "\r⠋ xcd: short 1s\u{1B}[K")
        #expect(Activity.frame(0, message: long, elapsed: 1, columns: nil).contains(long))
        #expect(Activity.frame(0, message: long, elapsed: 1, columns: 5) == "\r⠋ xcd: … 1s\u{1B}[K")   // too narrow: just the time
    }

    @Test func aPlainReporterPrintsTheMessageOnceWithoutControlCharacters() async throws {
        let lines = Recorder()
        let value = try await Activity.plain(lines.write).step("reading build settings of 12 schemes", done: "read") { 42 }
        #expect(value == 42)
        #expect(lines.all == ["reading build settings of 12 schemes"])
        #expect(!lines.all.joined().contains("\u{1B}") && !lines.all.joined().contains("\r"))
    }

    @Test func theSpinnerEndsWithAFinalLineAndWritesNothingAfterwards() async throws {
        let recorder = Recorder()
        let value = try await animated(recorder).step("resolving Swift packages", done: "resolved Swift packages") {
            await waitForFrames(recorder, 3)
            return "ok"
        }
        #expect(value == "ok")
        let writes = recorder.all
        #expect(writes.first?.hasPrefix("\r⠋ xcd: resolving Swift packages ") == true)
        #expect(writes.dropLast().allSatisfy { $0.hasPrefix("\r") && $0.hasSuffix("\u{1B}[K") })
        let last = try #require(writes.last)
        #expect(last.hasPrefix("\r\u{1B}[Kxcd: resolved Swift packages (") && last.hasSuffix("s)\n"))
        await Task.yield()
        #expect(recorder.all.count == writes.count)                            // the spinner has stopped
    }

    @Test func aThrownErrorClearsTheLineAndIsRethrown() async throws {
        let recorder = Recorder()
        await #expect(throws: XcdError.self) {
            try await animated(recorder).step("resolving Swift packages", done: "resolved") {
                await waitForFrames(recorder, 2)
                throw XcdError(.timeout, "timed out")
            }
        }
        #expect(recorder.all.last == "\r\u{1B}[K")
        let count = recorder.all.count
        await Task.yield()
        #expect(recorder.all.count == count)
    }

    @Test func anInterruptClearsTheLineAndRemovesTheRunsScratch() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("init-\(UUID().uuidString)").path
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("init-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: scratch + "/.xcdev", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: other) }
        Activity.removeOnInterrupt(scratch)
        Activity.removeOnInterrupt(other)
        Activity.keepOnInterrupt(other)                                        // that run ended normally
        let recorder = Recorder()
        let stopped = Counter()
        #expect(Activity.interrupted(write: recorder.write, stopChildren: { stopped.increment() }) == 130)
        #expect(stopped.value == 1)
        #expect(recorder.all == ["\r\u{1B}[K"])
        #expect(!FileManager.default.fileExists(atPath: scratch))
        #expect(FileManager.default.fileExists(atPath: other))
    }

    @Test func catchingInterruptsRestoresTheEarlierDisposition() {
        func current() -> Int {
            var action = sigaction()
            sigaction(SIGINT, nil, &action)
            return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
        }
        let before = current()
        let handler = InterruptHandler.install {}
        #expect(current() == unsafeBitCast(SIG_IGN, to: Int.self))            // the dispatch source gets it instead
        handler.remove()
        #expect(current() == before)
    }

    /// The step checks `fired` after its body, so a body that ends because Ctrl-C stopped its children prints nothing
    /// more while the handler cleans up and exits.
    @Test func aSIGINTRunsTheActionAndMarksTheHandlerFired() async throws {
        let ran = Counter()
        let handler = InterruptHandler.install { ran.increment() }
        defer { handler.remove() }
        #expect(!handler.fired)
        raise(SIGINT)                                                          // ignored by the process, seen by the source
        while ran.value == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(handler.fired && ran.value == 1)
    }

    /// Process resets the children's signals, so ignoring SIGINT in xcd doesn't make them ignore it.
    @Test func childrenStartedDuringAStepDontIgnoreSIGINT() async throws {
        let handler = InterruptHandler.install {}
        defer { handler.remove() }
        let output = try await SystemProcessRunner().run(Invocation("/bin/sh", ["-c", "kill -INT $$; echo survived"]))
        #expect(output.stdoutString.isEmpty && output.exitCode != 0)
    }

    /// Process starts each child in its own process group, which the terminal's Ctrl-C doesn't reach, so an
    /// interrupt stops them itself; otherwise an xcodebuild would outlive xcd and refill the scratch folder.
    @Test func anInterruptStopsTheRunningChildren() async throws {
        let argv = ["sleep", "30.\(Int.random(in: 1000...9999))"]               // other tests' children are left alone
        func mine() -> Bool { SystemProcessRunner.runningChildren.values.contains(argv) }
        let child = Task { try await SystemProcessRunner().run(Invocation("/bin/sleep", [argv[1]])) }
        while !mine() { try await Task.sleep(for: .milliseconds(5)) }
        SystemProcessRunner.terminateChildren { $0 == argv }
        #expect(!mine())                                                       // gone before the scratch is removed
        let output = try await child.value
        #expect(output.exitCode != 0)
    }

    @Test func animatesOnlyOnATerminalThatIsNotDumbAndNotForJSON() {
        #expect(Activity.animates(stderrIsTerminal: true, environment: ["TERM": "xterm-256color"], output: .text))
        #expect(Activity.animates(stderrIsTerminal: true, environment: [:], output: .text))
        #expect(!Activity.animates(stderrIsTerminal: false, environment: ["TERM": "xterm"], output: .text))
        #expect(!Activity.animates(stderrIsTerminal: true, environment: ["TERM": "dumb"], output: .text))
        #expect(!Activity.animates(stderrIsTerminal: true, environment: ["TERM": "xterm"], output: .json))
    }

    @Test func servicesAnimateOnlyWhenTheyHaveATerminalAndPrintText() {
        let lines = Recorder()
        let terminal = Recorder()
        var services = Services(runner: FakeProcessRunner(), globalPaths: GlobalPaths(base: "/tmp/none"), currentDirectory: "/",
                                environment: [:], progress: lines.write, terminal: terminal.write)
        #expect(services.activity.isAnimated)
        services.output = .json
        #expect(!services.activity.isAnimated)
        let plain = Services(runner: FakeProcessRunner(), globalPaths: GlobalPaths(base: "/tmp/none"), currentDirectory: "/",
                             environment: [:], progress: lines.write)
        #expect(!plain.activity.isAnimated)
    }
}
