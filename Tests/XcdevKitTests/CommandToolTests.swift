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

    /// The files are the shell's arguments, and the command says where they go: xcd adds nothing to it.
    @Test func theFilesGoWhereTheCommandNamesThem() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        let command = #"test -d App.xcodeproj && printf '[%s]\n' --strict "$@" | sort; echo "in the worktree as $0""#
        let result = try await tool().run(command, section: "lint", files: ["Sources/My App/A.swift", "Tests/T.swift"], in: ctx)
        #expect(result.exitCode == 0)
        #expect(result.output == "[--strict]\n[Sources/My App/A.swift]\n[Tests/T.swift]\nin the worktree as xcd-lint\n")
    }

    /// Put after the command, the files would be arguments of whatever it ends with: `tee` would write over them.
    @Test func aCommandThatDoesNotNameTheFilesLeavesThemAlone() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        try "let a = 1\n".write(toFile: worktree.root + "/A.swift", atomically: true, encoding: .utf8)
        let result = try await tool().run("echo findings | tee lint.out", section: "lint", files: ["A.swift"], in: ctx)
        #expect(result.output == "findings\n")
        #expect(try String(contentsOfFile: worktree.root + "/A.swift", encoding: .utf8) == "let a = 1\n")
    }

    /// A `run` written as a YAML block is several lines, and its last may end a compound command, which takes no
    /// arguments.
    @Test func aCommandOfSeveralLinesThatEndsInFiRunsAndKeepsItsExitCode() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        let command = "if [ \"$#\" -gt 0 ]; then\n  echo \"linting $# files\"\n  false\nfi\n"
        let result = try await tool().run(command, section: "lint", files: ["A.swift", "B.swift"], in: ctx)
        #expect(result.output == "linting 2 files\n")
        #expect(result.exitCode == 1)
        #expect(try await tool().run(command, section: "lint", files: [], in: ctx).exitCode == 0)
    }

    @Test func whetherACommandNamesItsFilesIsReadFromItsText() {
        for command in [#"./scripts/lint.sh "$@""#, "mytool lint $*", #"for f in "${@}"; do lint "$f"; done"#, #"lint "$1""#, "lint ${2}"] {
            #expect(CommandTool.namesItsFiles(command), "\(command)")
        }
        for command in ["./scripts/lint.sh", "echo $HOME ${PATH}", #"echo "as $0""#, "echo 5$", "echo $", "echo ${"] {
            #expect(!CommandTool.namesItsFiles(command), "\(command)")
        }
    }

    @Test func aCommandThatLeftItsFilesUnnamedGetsANote() {
        #expect(CommandTool.unnamedFilesNote("./scripts/lint.sh", section: "lint", files: 2)
                == #"lint.run has no "$@", so the command did not get the 2 files in scope; write "$@" where the files go"#)
        #expect(CommandTool.unnamedFilesNote("./scripts/lint.sh", section: "lint", files: 1)
                == #"lint.run has no "$@", so the command did not get the 1 file in scope; write "$@" where the files go"#)
        #expect(CommandTool.unnamedFilesNote("./scripts/lint.sh", section: "lint", files: 0) == nil)       // --all: none to get
        #expect(CommandTool.unnamedFilesNote(#"./scripts/lint.sh "$@""#, section: "lint", files: 2) == nil)
    }

    @Test func outputThatIsNotUTF8IsStillShown() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        let result = try await tool().run(#"printf 'one\n\351 two\n'; exit 1"#, section: "lint", files: [], in: ctx)
        #expect(result.exitCode == 1)
        #expect(result.output.contains("one") && result.output.contains("two"))
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
            _ = try await tool().run("./scripts/lint.sh \"$@\"\n", section: "lint", files: ["A.swift"], in: ctx)
        }
        #expect(missing?.code == .subprocessFailed)
        #expect(missing?.message == "the project's lint command could not be run (exit 127)")
        #expect(missing?.next == "its command was not found; check lint.run in .xcdev.yml (paths are relative to the worktree root)")
        #expect(missing?.details.first == "command: ./scripts/lint.sh \"$@\"")                  // without the block's newline
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
        #expect(try await tool().run("echo $#", section: "lint", files: fits, in: ctx).output == "2500\n")

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
