import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Running a project's own lint command. The command runs through a real /bin/sh.
@Suite struct CommandToolTests {
    let worktree = FakeWorktree(prefix: "xcd tool")
    var fake: FakeProcessRunner { worktree.runner }

    func tool(timeout: Duration = CommandTool.timeout) -> CommandTool {
        CommandTool(runner: RoutingRunner(fake: fake, realExecutables: ["sh"]), output: .json, timeout: timeout,
                    now: { Date(timeIntervalSince1970: 1_790_040_000) })
    }

    func context() throws -> WorktreeContext {
        try worktree.context("version: 1\nproject: App.xcodeproj\nlint:\n  run: ./scripts/lint.sh\n", container: "App.xcodeproj")
    }

    func lintLogs(_ ctx: WorktreeContext) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: ctx.paths.logs)) ?? []).filter { $0.hasSuffix("-lint.log") }.sorted()
    }

    @Test func aCommandEndedByANewlineKeepsItsExitCode() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        #expect(try await tool().run("false\n", section: "lint", files: [], in: ctx).exitCode == 1)
    }

    @Test func aCommandEndedByANewlineGetsAPathWithASpaceAsOneArgument() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        let result = try await tool().run("printf '[%s]\\n'\n\n", section: "lint", files: ["My App/A.swift"], in: ctx)
        #expect(result.exitCode == 0)
        #expect(result.output == "[My App/A.swift]\n")
    }

    /// After a `;` the files would be a command of their own, and with no files its exit code would be the result.
    @Test func aCommandEndedByASemicolonKeepsItsExitCode() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        let ended = try await tool().run("false;", section: "lint", files: [], in: ctx)
        #expect(ended.exitCode == 1)
        let spaced = try await tool().run("false ; \n", section: "lint", files: [], in: ctx)
        #expect(spaced.exitCode == 1)
    }

    /// A `;` after a backslash is an argument of the command, as in `find … -exec … \;`, so it is not the command's end.
    @Test func anEscapedSemicolonAtTheEndStaysAnArgument() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        let result = try await tool().run(#"printf '[%s]\n' a\;"#, section: "lint", files: ["B.swift"], in: ctx)
        #expect(result.output == "[a;]\n[B.swift]\n")
        // Two backslashes are a backslash, so the `;` after them does end the command.
        let ended = try await tool().run(#"printf '[%s]\n' a\\;"#, section: "lint", files: ["B.swift"], in: ctx)
        #expect(ended.output == "[a\\]\n[B.swift]\n")
    }

    @Test func outputThatIsNotUTF8IsStillShown() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        let result = try await tool().run(#"printf 'one\n\351 two\n'; exit 1"#, section: "lint", files: [], in: ctx)
        #expect(result.exitCode == 1)
        #expect(result.output.contains("one") && result.output.contains("two"))
    }

    @Test func theFilesArriveAsArgumentsAfterTheCommandsOwn() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        // xcd puts the files after the command as written, so they follow the command's own arguments.
        let command = #"test -d App.xcodeproj && echo "in the worktree as $0"; printf '[%s]\n' --strict"#
        let result = try await tool().run(command, section: "lint", files: ["Sources/My App/A.swift", "Tests/T.swift"], in: ctx)
        #expect(result.exitCode == 0)
        #expect(result.output == "in the worktree as xcd-lint\n[--strict]\n[Sources/My App/A.swift]\n[Tests/T.swift]\n")
    }

    @Test func theCommandGetsTheWorktreesContext() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        let result = try await tool().run(#"echo "$XCD_WORKTREE_NAME $XCD_OUTPUT $# ${XCD_DEVICE-no device}"; echo "$XCD_WORKTREE""#,
                                          section: "lint", files: [], in: ctx)
        #expect(result.output == "feat json 0 no device\n\(worktree.root)\n")                // no files: no arguments
    }

    @Test func whatItPrintsIsKeptInOrderAndLogged() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        let result = try await tool().run("echo one; echo two >&2; echo three; exit 3", section: "lint", files: [], in: ctx)
        #expect(result.exitCode == 3)                                          // returned, not thrown: the report decides
        #expect(result.output == "one\ntwo\nthree\n")
        #expect(result.log.hasPrefix(worktree.root + "/.xcdev/logs/") && result.log.hasSuffix("-lint.log"))
        #expect(try String(contentsOfFile: result.log, encoding: .utf8) == "one\ntwo\nthree\n")
    }

    @Test func aCommandTheShellCannotRunIsNotALintFailure() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        let missing = await #expect(throws: XcdError.self) {
            _ = try await tool().run("./scripts/lint.sh", section: "lint", files: ["A.swift"], in: ctx)
        }
        #expect(missing?.code == .subprocessFailed)
        #expect(missing?.message == "the project's lint command could not be run (exit 127)")
        #expect(missing?.next == "its command was not found; check lint.run in .xcdev.yml (paths are relative to the worktree root)")
        #expect(missing?.details.first == "command: ./scripts/lint.sh")
        #expect(missing?.details.dropFirst().first?.hasPrefix("log: \(worktree.root)/.xcdev/logs/") == true)

        try FileManager.default.createDirectory(atPath: worktree.root + "/scripts", withIntermediateDirectories: true)
        try "#!/bin/sh\necho hi\n".write(toFile: worktree.root + "/scripts/lint.sh", atomically: true, encoding: .utf8)
        let notExecutable = await #expect(throws: XcdError.self) {
            _ = try await tool().run("./scripts/lint.sh", section: "lint", files: [], in: ctx)
        }
        #expect(notExecutable?.message == "the project's lint command could not be run (exit 126)")
        #expect(notExecutable?.next == "its script is not executable; run `chmod +x` on it")
    }

    /// A command line holds about a megabyte. The list is never split over several runs: a script may count on
    /// seeing all of it.
    @Test func aFileListTooLongForOneCommandLineIsAUsageError() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        let name = String(repeating: "a", count: 99)                           // 100 bytes with its separator
        let fits = Array(repeating: name, count: 2_500)
        #expect(try await tool().run("echo $#", section: "lint", files: fits, in: ctx).output.hasPrefix("2500 aaa"))

        let before = lintLogs(ctx)
        let error = await #expect(throws: XcdError.self) {
            _ = try await tool().run("touch ran; echo $#", section: "lint", files: fits + ["b"], in: ctx)
        }
        #expect(!FileManager.default.fileExists(atPath: worktree.root + "/ran"))    // nothing ran
        #expect(lintLogs(ctx) == before)
        #expect(error?.code == .usage)
        #expect(error?.message == "2501 files are too many to hand to lint.run on one command line")
        #expect(error?.next == "pass --all with no paths so the command covers the project its own way, or name fewer paths")
    }

    @Test func aCommandThatRunsTooLongIsStopped() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        let marker = worktree.root + "/finished"
        let error = await #expect(throws: XcdError.self) {
            _ = try await tool(timeout: .milliseconds(300)).run("sleep 30; touch finished", section: "lint", files: [], in: ctx)
        }
        #expect(error?.code == .timeout)
        #expect(error?.message == "the project's lint command timed out after 0.3s")
        #expect(error?.next == "make lint.run finish sooner, or name paths to give it fewer files")
        #expect(error?.details.first == "command: sleep 30; touch finished")
        #expect(error?.details.count == 2 && error?.details.last?.hasPrefix("log: \(worktree.root)/.xcdev/logs/") == true)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }
}
