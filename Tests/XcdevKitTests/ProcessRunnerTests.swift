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
}
