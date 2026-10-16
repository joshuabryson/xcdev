import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// A git command that fails is reported as git's failure, in git's words. The
/// fake runner prints what `/usr/bin/git` 2.54.0 printed when run for real.
@Suite struct GitFailureTests {
    let fake = FakeProcessRunner()

    func failure(of arguments: [String], next: String? = nil) async -> XcdError? {
        await #expect(throws: XcdError.self) { try await fake.runChecked(.git(arguments, in: "/r"), next: next) }
    }

    @Test func aFailedGitCommandIsGitFailedWithGitsOwnWords() async {
        fake.stub(["git", "-C", "/r", "diff"], exitCode: 128, stderr: "fatal: bad revision 'f00'\n")
        let error = await failure(of: ["diff", "f00"])
        #expect(error?.code == .gitFailed && error?.code.exitCode == 3)
        #expect(error?.message == "git failed: bad revision 'f00'")
        #expect(error?.next == "fix what git says above, then run the command again")
        #expect(error?.details == ["command: git -C /r diff f00", "exit: 128", "fatal: bad revision 'f00'"])
    }

    @Test func gitsLastTwentyLinesAreKeptAndAnyCallersNextToo() async {
        let lines = (1...25).map { "error: line \($0)" }
        fake.stub(["git", "-C", "/r", "worktree"], exitCode: 255, stderr: lines.joined(separator: "\n") + "\n")
        let error = await failure(of: ["worktree", "remove", "--force", "/w"], next: "close anything using the worktree")
        #expect(error?.message == "git failed: line 1")
        #expect(error?.next == "close anything using the worktree")
        #expect(error?.details.dropFirst(2) == ArraySlice(lines.suffix(20)))
    }

    @Test func gitThatSaysNothingIsStillGitFailed() async {
        fake.stub(["git", "-C", "/r", "status"], exitCode: 129)
        let error = await failure(of: ["status", "--porcelain"])
        #expect(error?.code == .gitFailed && error?.message == "`git status --porcelain` failed (exit 129)")
    }

    /// Another user's repository: git names its own fix, which changes the person's global config, so the agent asks first.
    @Test func dubiousOwnershipSaysToAskTheUser() async {
        fake.stub(["git"], exitCode: 128, stderr: """
            fatal: detected dubious ownership in repository at '/Users/sam/Shared App'
            To add an exception for this directory, call:

            \tgit config --global --add safe.directory '/Users/sam/Shared App'

            """)
        let error = await failure(of: ["ls-files"], next: "a caller's own advice")
        #expect(error?.code == .gitFailed)
        #expect(error?.message == "git refuses this repository because another user owns it")
        #expect(error?.next == "ask the user whether to trust it; git's own fix is `git config --global --add safe.directory '/Users/sam/Shared App'`")
    }

    /// The git holding a lock may be another agent's, whatever git suggests about removing the file by hand.
    @Test func aLockFileSaysToWaitAndToAskBeforeDeletingIt() async {
        let held = "Another git process seems to be running in this repository, or the lock file may be stale"
        fake.stub(["git", "-C", "/r", "add"], exitCode: 128, stderr: "fatal: Unable to create '/r/.git/index.lock': File exists.\n\n\(held)\n")
        fake.stub(["git", "-C", "/r", "worktree"], exitCode: 255,
                  stderr: "fatal: cannot lock ref 'refs/heads/x': Unable to create '/r/.git/refs/heads/x.lock': File exists.\n\n\(held)\n")
        let index = await failure(of: ["add", "-A"])
        #expect(index?.message == "git failed: Unable to create '/r/.git/index.lock': File exists.")
        #expect(index?.next == "another git command is using this repository, maybe another agent's: wait a moment and run the command again; "
                    + "ask the user before deleting /r/.git/index.lock")
        let ref = await failure(of: ["worktree", "add", "-b", "x", "/w", "HEAD"], next: "a caller's own advice")
        #expect(ref?.message == "git failed: cannot lock ref 'refs/heads/x': Unable to create '/r/.git/refs/heads/x.lock': File exists.")
        #expect(ref?.next?.hasSuffix("ask the user before deleting /r/.git/refs/heads/x.lock") == true)
    }

    @Test func otherToolsAreStillSubprocessFailed() async {
        fake.stub(["xcrun"], exitCode: 1, stderr: "xcrun: error: unable to find utility\n")
        let error = await #expect(throws: XcdError.self) { try await fake.runChecked(.xcrun(["simctl", "list"], developerDir: nil)) }
        #expect(error?.code == .subprocessFailed)
    }

    @Test func helpErrorsListsTheCodeAndExit3SaysToFollowNext() {
        let row = ErrorsReport().errors.first { $0.code == "git_failed" }
        #expect(row?.exitCode == 3 && row?.summary == "git itself failed, rather than answering \"no\"; git's message follows.")
        #expect(ErrorsReport().text.hasPrefix(
            "exit codes: 1 = the task failed (fix the code), 2 = fix the command line or config, 3 = fix the environment: do what `next:` says (often `xcd doctor`)\n"))
    }
}
