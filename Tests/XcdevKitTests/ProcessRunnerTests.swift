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

    /// The tests of deadlines and cancellation use no clock: in a full run a test waits seconds for its turn behind
    /// the suite's others, so a bound on the time taken fails on a busy Mac. Each child instead says "finished" (or
    /// leaves a file) when it gets to its own end, 30 seconds on; that it never did shows what ended it.
    @Test func timeoutTerminatesAndThrows() async throws {
        let error = await #expect(throws: XcdError.self) {
            try await runner.run(Invocation("/bin/sh", ["-c", "sleep 30; echo finished >&2"], timeout: .milliseconds(100)))
        }
        #expect(error?.code == .timeout)
        #expect(error?.details.contains("finished") == false)
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

    /// The sleep ignores SIGTERM too: a signal its shell ignores stays ignored in what the shell starts.
    @Test func timeoutEscalatesToKillWhenTermIsIgnored() async throws {
        let runner = SystemProcessRunner(killAfter: .milliseconds(100))
        let error = await #expect(throws: XcdError.self) {
            try await runner.run(Invocation("/bin/sh", ["-c", "trap '' TERM; sleep 30; echo finished >&2"],
                                            timeout: .milliseconds(300)))
        }
        #expect(error?.code == .timeout)
        #expect(error?.details.contains("finished") == false)
    }

    @Test func cancellationThrowsCancellationError() async throws {
        let finished = FileManager.default.temporaryDirectory.appendingPathComponent("xcd finished \(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: finished) }
        let runner = self.runner
        let task = Task { try await runner.run(Invocation("/bin/sh", ["-c", "sleep 30; touch '\(finished)'"])) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: finished), "the child ran to its end")
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
        let out = try await runner.run(Invocation("/bin/sh", ["-c", "echo started; exec sleep 30"],
                                                  timeout: .milliseconds(500), stopAtTimeout: true))
        #expect(out.stdoutString == "started\n")
        #expect(out.stoppedAtDeadline && out.exitCode == 143)                // 128 + SIGTERM; a sleep that ended by itself gives 0
    }

    /// `XCD_TIMEOUT_SCALE` stretches a limit: a 0.4 s sleep under a 0.2 s limit, five times as long, finishes.
    @Test func theTimeoutScaleStretchesALimit() async throws {
        let scaled = SystemProcessRunner(inheritedEnvironment: ["XCD_TIMEOUT_SCALE": "5"])
        let out = try await scaled.run(Invocation("/bin/sh", ["-c", "sleep 0.4; echo done"], timeout: .milliseconds(200)))
        #expect(out.exitCode == 0 && out.stdoutString == "done\n")
    }

    /// A deadline that is how long to watch, not a limit, keeps its length: the 0.2 s deadline stops a child that would
    /// end by itself at 3 s, long before the 10 s the scale would make of it.
    @Test func theTimeoutScaleLeavesAStopAtTimeoutAlone() async throws {
        let scaled = SystemProcessRunner(inheritedEnvironment: ["XCD_TIMEOUT_SCALE": "50"])
        let out = try await scaled.run(Invocation("/bin/sh", ["-c", "sleep 3; echo ended"], timeout: .milliseconds(200), stopAtTimeout: true))
        #expect(out.stoppedAtDeadline)
        #expect(!out.stdoutString.contains("ended"))
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

    /// A timeout ends the child's whole process group, so a background job can't keep the output pipe open.
    @Test func aTimeoutStopsWhatTheChildStarted() async throws {
        let out = try await runner.run(Invocation("/bin/sh", ["-c", "(sleep 30; echo finished) & echo $!; wait"],
                                                  timeout: .milliseconds(500), stopAtTimeout: true))
        #expect(out.stoppedAtDeadline)
        #expect(!out.stdoutString.contains("finished"))                       // a job left running would say so, into the pipe
        let sleeper = try #require(pid_t(out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = ContinuousClock.now + .seconds(10)                     // launchd reaps it soon after
        while kill(sleeper, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(kill(sleeper, 0) != 0)
    }

    /// stdin, stdout, and stderr go to the child's 0, 1, and 2 before /dev/null is opened as its stdin, so a
    /// descriptor numbered 0 (when xcd's own stdin was closed) isn't replaced first.
    @Test func redirectedOutputIsDuplicatedBeforeStdinIsOpened() {
        #expect(ChildProcess.fileActions(for: .redirected(output: 0, error: 5), isOpen: { _ in true })
                == [.duplicate(0, to: 1), .duplicate(5, to: 2), .openNull(0, flags: O_RDONLY)])
    }

    /// A passthrough child shares what xcd has open of 0, 1, and 2; one xcd's parent closed becomes /dev/null.
    @Test func aPassthroughChildGetsDevNullForAClosedDescriptor() {
        #expect(ChildProcess.fileActions(for: .shared, isOpen: { $0 != 0 && $0 != 2 })
                == [.openNull(0, flags: O_RDONLY), .inherit(1), .openNull(2, flags: O_WRONLY)])
        #expect(ChildProcess.fileActions(for: .shared, isOpen: { _ in true }) == [.inherit(0), .inherit(1), .inherit(2)])
    }

    @Test func aMissingWorkingDirectoryIsALaunchFailure() async throws {
        let error = await #expect(throws: XcdError.self) {
            try await runner.run(Invocation("/bin/echo", [], workingDirectory: "/no/such/folder"))
        }
        #expect(error?.code == .subprocessFailed)
        #expect(error?.message == "could not launch /bin/echo: its working directory /no/such/folder does not exist")
    }

    /// A nested xcd (inside a project command, plugin, or hook) inherits its parent's context; a variable that
    /// doesn't apply to this child must be unset, not the parent's stale value.
    @Test func inheritedContextVariablesDoNotLeakIntoAChild() async throws {
        let inherited = ["PATH": "/usr/bin:/bin", "XCD_UDID": "STALE-UDID", "XCD_APP_PATH": "/stale/App.app",
                         "XCD_WORKTREE_NAME": "parent", "XCD_OUTPUT": "json", "DEVELOPER_DIR": "/Inherited.app",
                         "XCD_UNRELATED": "kept"]
        let state = WorktreeState(id: "id", name: "feat", project: "App", projectRoot: "/p", path: "/p/wt", branch: "feat",
                                  xcode: nil, devices: [:], status: .ready, createdAt: Date())
        let context = ContextInfo.worktree(state, config: nil).environment
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

    @Test func inputFileBecomesStdin() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("xcd stdin \(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: file) }
        try "hello pasteboard".write(toFile: file, atomically: true, encoding: .utf8)
        let out = try await SystemProcessRunner().run(Invocation("/bin/cat", [], inputFile: file))
        #expect(out.stdoutString == "hello pasteboard")
    }
}
