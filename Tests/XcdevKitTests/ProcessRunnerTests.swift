import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct ProcessRunnerTests {
    let runner = SystemProcessRunner()

    @Test func capturesStdoutAndExitCode() async throws {
        let out = try await runner.run(Invocation("/bin/echo", ["hello world"]))
        #expect(out.exitCode == 0)
        #expect(out.stdoutString == "hello world\n")
    }

    @Test func nonZeroExitIsReturnedNotThrown() async throws {
        let out = try await runner.run(Invocation("/bin/sh", ["-c", "echo oops >&2; exit 3"]))
        #expect(out.exitCode == 3)
        #expect(out.stderrString == "oops\n")
    }

    @Test func runCheckedThrowsWithStderrTail() async throws {
        let error = await #expect(throws: XcdError.self) {
            try await runner.runChecked(Invocation("/bin/sh", ["-c", "echo bad thing >&2; exit 4"]),
                                        code: .simulatorFailed, next: "run `xcd doctor`")
        }
        #expect(error?.code == .simulatorFailed)
        #expect(error?.next == "run `xcd doctor`")
        #expect(error?.details.contains("exit: 4") == true)
        #expect(error?.details.last == "bad thing")
    }

    @Test func environmentIsMergedIntoChild() async throws {
        let out = try await runner.run(Invocation("/usr/bin/env", [], environment: ["XCD_TEST_VAR": "yes"]))
        #expect(out.stdoutString.contains("XCD_TEST_VAR=yes"))
    }

    @Test func timeoutTerminatesAndThrows() async throws {
        let start = ContinuousClock.now
        let error = await #expect(throws: XcdError.self) {
            try await runner.run(Invocation("/bin/sleep", ["5"], timeout: .milliseconds(300)))
        }
        #expect(error?.code == .timeout)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func missingExecutableThrowsSubprocessFailed() async throws {
        let error = await #expect(throws: XcdError.self) {
            try await runner.run(Invocation("/no/such/tool", []))
        }
        #expect(error?.code == .subprocessFailed)
    }

    @Test func argvAndCommandLineUseBasenameAndQuoting() {
        let inv = Invocation.git(["status"], in: "/tmp/a b")
        #expect(inv.argv == ["git", "-C", "/tmp/a b", "status"])
        #expect(inv.commandLine == "git -C '/tmp/a b' status")
        let x = Invocation.xcrun(["simctl", "list"], developerDir: "/X.app/Contents/Developer")
        #expect(x.environment == ["DEVELOPER_DIR": "/X.app/Contents/Developer"])
        #expect(Invocation.xcrun(["simctl"], developerDir: nil).environment.isEmpty)
    }

    @Test func fakeRunnerMatchesLatestStubByPrefix() async throws {
        let fake = FakeProcessRunner()
        fake.stub(["git"], stdout: "generic")
        fake.stub(["git", "-C", "/r", "status"], stdout: "specific")
        #expect(try await fake.run(.git(["status"], in: "/r")).stdoutString == "specific")
        #expect(try await fake.run(.git(["log"], in: "/r")).stdoutString == "generic")
        #expect(fake.commandLines == ["git -C /r status", "git -C /r log"])
        await #expect(throws: XcdError.self) { try await fake.run(Invocation("/usr/bin/xcrun", ["simctl"])) }
    }

    @Test func timeoutEscalatesToKillWhenTermIsIgnored() async throws {
        let start = ContinuousClock.now
        let error = await #expect(throws: XcdError.self) {
            try await runner.run(Invocation("/bin/sh", ["-c", "trap '' TERM; while true; do sleep 0.1; done"],
                                            timeout: .milliseconds(300)))
        }
        #expect(error?.code == .timeout)
        #expect(ContinuousClock.now - start < .seconds(8))
    }

    @Test func cancellationThrowsCancellationError() async throws {
        let runner = self.runner
        let start = ContinuousClock.now
        let task = Task { try await runner.run(Invocation("/bin/sleep", ["30"])) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func outputFileReceivesBothStreamsAndAppends() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-out-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/logs dir/out.log"
        let first = try await runner.run(Invocation("/bin/sh", ["-c", "echo one; echo two >&2; exit 5"], outputFile: file))
        #expect(first.exitCode == 5)
        #expect(first.stdout.isEmpty && first.stderr.isEmpty)
        _ = try await runner.run(Invocation("/bin/echo", ["three"], outputFile: file))
        let text = try String(contentsOfFile: file, encoding: .utf8)
        #expect(text.contains("one\n") && text.contains("two\n"))
        #expect(text.hasSuffix("three\n"))
    }

    @Test func stopAtTimeoutReturnsWhatWasCaptured() async throws {
        let start = ContinuousClock.now
        let out = try await runner.run(Invocation("/bin/sh", ["-c", "echo started; exec sleep 10"],
                                                  timeout: .milliseconds(500), stopAtTimeout: true))
        #expect(out.stdoutString == "started\n")
        #expect(out.stoppedAtDeadline && !out.succeeded)
        #expect(ContinuousClock.now - start < .seconds(4))
    }

    @Test func aProcessThatEndsBeforeItsDeadlineWasNotStopped() async throws {
        let out = try await runner.run(Invocation("/bin/sh", ["-c", "exit 3"], timeout: .seconds(5), stopAtTimeout: true))
        #expect(out.exitCode == 3 && !out.stoppedAtDeadline)
    }

    @Test func fakeRunnerKeepsTheDeadlineStopWithAnOutputFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-fake-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fake = FakeProcessRunner()
        fake.stub(["log", "stream"]) { _ in
            var output = ProcessOutput(exitCode: 15, stdout: "line\n")
            output.stoppedAtDeadline = true
            return output
        }
        let out = try await fake.run(Invocation("/usr/bin/log", ["stream"], outputFile: dir + "/s.log", stopAtTimeout: true))
        #expect(out.stoppedAtDeadline && out.exitCode == 15 && out.stdout.isEmpty)
    }

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

    /// A nested xcd (inside a project command, plugin, or hook) inherits its parent's context; a variable that
    /// doesn't apply to this child must be unset, not the parent's stale value.
    @Test func inheritedContextVariablesDoNotLeakIntoAChild() async throws {
        let inherited = ["PATH": "/usr/bin:/bin", "XCD_UDID": "STALE-UDID", "XCD_APP_PATH": "/stale/App.app",
                         "XCD_WORKTREE_NAME": "parent", "XCD_OUTPUT": "json", "DEVELOPER_DIR": "/Inherited.app",
                         "XCD_UNRELATED": "kept"]
        let state = WorktreeState(id: "id", name: "feat", project: "App", projectRoot: "/p", path: "/p/wt", branch: "feat",
                                  xcode: nil, devices: [:], status: .ready, createdAt: Date())
        let context = ContextInfo.worktree(state).environment
        let script = #"for v in XCD_UDID XCD_APP_PATH XCD_OUTPUT XCD_WORKTREE_NAME DEVELOPER_DIR XCD_UNRELATED; do eval "printf '%s=%s\n' $v \"\${$v-unset}\""; done"#
        let out = try await SystemProcessRunner(inheritedEnvironment: inherited)
            .run(Invocation("/bin/sh", ["-c", script], environment: context))
        #expect(out.stdoutString == """
            XCD_UDID=unset
            XCD_APP_PATH=unset
            XCD_OUTPUT=unset
            XCD_WORKTREE_NAME=feat
            DEVELOPER_DIR=/Inherited.app
            XCD_UNRELATED=kept

            """)
    }

    @Test func fakeRunnerHonorsOutputFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-fake-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fake = FakeProcessRunner()
        fake.stub(["xcrun", "xcodebuild"], exitCode: 65, stdout: "compiling\n", stderr: "** BUILD FAILED **\n")
        let out = try await fake.run(Invocation("/usr/bin/xcrun", ["xcodebuild"], outputFile: dir + "/b.log"))
        #expect(out.exitCode == 65 && out.stdout.isEmpty)
        #expect(try String(contentsOfFile: dir + "/b.log", encoding: .utf8) == "compiling\n** BUILD FAILED **\n")
    }
}
