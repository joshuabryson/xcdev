import Foundation
import Testing
@testable import XcdevKit

/// Every test that changes this process's real signal dispositions: running a passthrough child (which ignores
/// SIGINT and SIGQUIT while it runs), ignoring SIGINT, or installing the handler. Serialized so none of them can
/// save or restore a disposition another has changed, and none can leave SIGINT at its default while another expects
/// it ignored. Nothing here raises a signal in the test process.
@Suite(.serialized) struct SignalDispositionTests {
    let runner = SystemProcessRunner(interrupts: Interrupts(report: { _ in }))

    static func current(_ signal: Int32) -> Int {
        var action = sigaction()
        sigaction(signal, nil, &action)
        return unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
    }

    static let ignored = unsafeBitCast(SIG_IGN, to: Int.self)

    @Test func passthroughSharesStdioAndReturnsTheExitCode() async throws {
        let out = try await runner.run(Invocation("/bin/sh", ["-c", "exit 7"], passthrough: true))
        #expect(out.exitCode == 7)
        #expect(out.stdout.isEmpty && out.stderr.isEmpty)
    }

    @Test func passthroughWinsOverAnOutputFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-pass-\(UUID().uuidString).log").path
        defer { try? FileManager.default.removeItem(atPath: file) }
        _ = try await runner.run(Invocation("/usr/bin/true", [], outputFile: file, passthrough: true))
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test func aPassthroughChildEndedByASignalReports128PlusTheSignal() async throws {
        let out = try await runner.run(Invocation("/bin/sh", ["-c", "kill -INT $$"], passthrough: true))
        #expect(out.exitCode == 130)
    }

    @Test func aPassthroughChildRunsWithSIGINTAndSIGQUITIgnoredInXcdThenRestored() throws {
        let before = (Self.current(SIGINT), Self.current(SIGQUIT))
        let interrupts = Interrupts(report: { _ in })
        let child = try interrupts.launch(["xcd-asker"], foreground: true) { ChildProcess(pid: 100_051, leadsGroup: false) }
        #expect(Self.current(SIGINT) == Self.ignored && Self.current(SIGQUIT) == Self.ignored)
        interrupts.finished(child)
        #expect((Self.current(SIGINT), Self.current(SIGQUIT)) == before)
    }

    /// Children start with default signal handling, so ignoring SIGINT in xcd doesn't make them ignore it.
    @Test func childrenStartedWhileXcdIgnoresSIGINTDontIgnoreIt() async throws {
        var ignore = sigaction()
        var previous = sigaction()
        ignore.__sigaction_u.__sa_handler = SIG_IGN
        sigaction(SIGINT, &ignore, &previous)
        defer { sigaction(SIGINT, &previous, nil) }
        let output = try await runner.run(Invocation("/bin/sh", ["-c", "kill -INT $$; echo survived"]))
        #expect(output.stdoutString.isEmpty && output.exitCode == 130)
    }

    /// The handler takes SIGINT, SIGTERM, and SIGHUP (the terminal closed) from the process, and gives them back.
    @Test func installingTakesSIGINTSIGTERMAndSIGHUPAndUninstallingRestoresThem() {
        let signals = [SIGINT, SIGTERM, SIGHUP]
        let before = signals.map(Self.current)
        let interrupts = Interrupts(report: { _ in })
        interrupts.install(exit: { _ in })
        #expect(signals.map(Self.current) == [Self.ignored, Self.ignored, Self.ignored])   // the sources get them
        interrupts.uninstall()
        #expect(signals.map(Self.current) == before)
    }

    /// Under `nohup`, SIGHUP is ignored on purpose: closing the terminal must not stop xcd or its children.
    @Test func aSIGHUPIgnoredAtStartIsLeftAlone() {
        var ignore = sigaction()
        var previous = sigaction()
        ignore.__sigaction_u.__sa_handler = SIG_IGN
        sigaction(SIGHUP, &ignore, &previous)
        defer { sigaction(SIGHUP, &previous, nil) }
        let interrupts = Interrupts(report: { _ in })
        interrupts.install(exit: { _ in })
        defer { interrupts.uninstall() }
        #expect(!interrupts.handles(SIGHUP))
        #expect(interrupts.handles(SIGINT) && interrupts.handles(SIGTERM))
    }
}
