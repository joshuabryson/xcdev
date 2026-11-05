import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Runs everything for real, and has git act as if another user owned every repository, as git does for a
/// repository on a shared or external disk. The switch is git's own test variable,
/// set on each git command only. An empty `safe.directory`, given last, empties git's list of safe repositories, so
/// a global `safe.directory = *` (GitHub's macOS runners set one) cannot make the repository safe again.
/// `calls` records every command's argv.
struct OwnedByAnotherUser: ProcessRunning {
    let real = SystemProcessRunner()
    let calls = Shared<[[String]]>([])

    func run(_ invocation: Invocation) async throws -> ProcessOutput {
        var invocation = invocation
        if invocation.argv.first == "git" {
            invocation.environment["GIT_TEST_ASSUME_DIFFERENT_OWNER"] = "1"
            invocation.environment["GIT_CONFIG_COUNT"] = "1"
            invocation.environment["GIT_CONFIG_KEY_0"] = "safe.directory"
            invocation.environment["GIT_CONFIG_VALUE_0"] = ""
        }
        calls.change { $0.append(invocation.argv) }
        return try await real.run(invocation)
    }
}

/// git's "no" is an answer, and any other failure of git is git's. Real git.
@Suite struct GitAnswersTests {
    /// `main` with one commit, then branch `work` checked out with one more.
    func project() throws -> TempProject {
        let project = try TempProject.make(config: "version: 1\nproject: App.xcodeproj\nlint:\n  tool: swiftlint\n")
        try project.git("checkout", "-q", "-b", "work")
        try project.write("work\n", to: "work.txt")
        try project.commit("Work")
        return project
    }

    @Test func gitsNoIsNilAndGitsFailureIsThrown() async throws {
        let project = try project()
        defer { project.remove() }
        let git = GitQuery(runner: SystemProcessRunner(), directory: project.root)
        #expect(try await git.commit("nosuch") == nil)
        #expect(try await git.fullName("HEAD~1") == nil)                    // a commit with no name
        #expect(try await git.fullName("HEAD") == "refs/heads/work")
        #expect(try await git.isShallow() == false)
        let refused = await #expect(throws: XcdError.self) {
            try await GitQuery(runner: OwnedByAnotherUser(), directory: project.root).commit("HEAD")
        }
        #expect(refused?.code == .gitFailed && refused?.message == "git refuses this repository because another user owns it")
    }

    /// Only an exit 1 with nothing on stderr is git's "no": a git that exits 1 and says why has failed.
    @Test func anExit1WithAMessageIsAFailure() async {
        let fake = FakeProcessRunner()
        fake.stub(["git"], exitCode: 1, stderr: "error: could not read the index\n")
        let error = await #expect(throws: XcdError.self) { try await GitQuery(runner: fake, directory: "/r").commit("HEAD") }
        #expect(error?.code == .gitFailed && error?.message == "git failed: could not read the index")
    }

    /// The three messages are for git's "no" only: a repository git refuses is not one with no commits.
    @Test func aBaseGitCannotReadIsGitFailedAndNotNoCommitsYet() async throws {
        let project = try project()
        defer { project.remove() }
        let error = await #expect(throws: XcdError.self) {
            try await BaseResolver(runner: OwnedByAnotherUser()).resolve(in: project.root, flag: nil, recorded: nil)
        }
        #expect(error?.code == .gitFailed)
    }

    /// A shallow clone whose cut hides where the work left main answers "no common commit" as unrelated histories do.
    @Test func aShallowCloneIsNamedAndToldHowToDeepenIt() async throws {
        let project = try project()
        defer { project.remove() }
        try project.git("checkout", "-q", "main")
        try project.write("later\n", to: "later.txt")
        try project.commit("Later on main")
        let clone = project.base + "/shallow"
        let url = "file://" + project.root.replacingOccurrences(of: " ", with: "%20")
        try TempProject.git(["clone", "-q", "--depth", "1", "--branch", "work", url, clone], in: project.base)
        try TempProject.git(["fetch", "-q", "--depth", "1", "origin", "main:main"], in: clone)
        let error = await #expect(throws: XcdError.self) {
            try await BaseResolver(runner: SystemProcessRunner()).resolve(in: clone, flag: nil, recorded: nil)
        }
        #expect(error?.code == .usage)
        #expect(error?.message == "HEAD and main have no commit in common in this shallow clone; its cut-off history may hide the one they share")
        #expect(error?.next == "deepen the clone with `git fetch --unshallow` (or `git fetch --deepen=<n>`) and run the command again, "
                    + "or pass --all to cover the whole project")
    }

    /// `wt create` reads the base before it makes anything, so a git that fails there leaves nothing behind.
    @Test func aBaseThatCannotBeReadStopsWorktreeCreateBeforeAnythingIsMade() async throws {
        let project = try project()
        defer { project.remove() }
        let home = GlobalPaths(base: project.home)
        let main = try await WorktreeService(runner: SystemProcessRunner(), globalPaths: home).open(from: project.root)
        let refused = OwnedByAnotherUser()
        let error = await #expect(throws: XcdError.self) {
            _ = try await WorktreeService(runner: refused, globalPaths: home).createRecordingBase(name: "login", in: main)
        }
        #expect(error?.code == .gitFailed)
        #expect(!refused.calls.value.contains { $0.contains("worktree") })              // git was never asked to add it
        #expect(try Registry(paths: home).entries().map(\.name) == ["main"])
        #expect(!FileManager.default.fileExists(atPath: project.base + "/Sample App.worktrees/login"))
        #expect(throws: XcdError.self) { try project.git("rev-parse", "--verify", "--quiet", "refs/heads/login") }
    }

    /// Only git's "that file is not there" means the file had no base version, so that all its findings count as new.
    @Test func aBaseVersionGitCannotShowIsGitFailed() async throws {
        let project = try project()
        defer { project.remove() }
        try project.write("func a() {\n    print(\"a\")\n}\n", to: "Sources/App/A.swift")
        let fake = FakeProcessRunner()
        let swiftlint = FakeSwiftLint()
        swiftlint.install(on: fake)
        let linter = SwiftLintLinter(tool: SwiftLintTool(runner: RoutingRunner(fake: fake, realExecutables: ["git"]), executable: "/bin/swiftlint", args: []),
                                     worktreeRoot: project.root, interrupts: Interrupts())
        let added = ScopedFile(path: "Sources/App/A.swift", basePath: "Sources/App/A.swift")   // not in the fork point
        let fork = try project.rev("main")
        #expect(try await linter.lint([added], against: fork).findings.count == 1)
        // git does not look up a whole hash it is shown, and answers "not there" for one it does not know.
        let unknown = "deadbeef"
        let error = await #expect(throws: XcdError.self) { _ = try await linter.lint([added], against: unknown) }
        #expect(error?.code == .gitFailed && error?.message == "git failed: invalid object name '\(unknown)'.")
    }
}
