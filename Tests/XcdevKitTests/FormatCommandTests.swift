import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// What a project's own format command needs beyond the lint one: a second command under `check`,
/// and telling which files a run rewrote. The commands run through a real /bin/sh.
@Suite struct FormatCommandTests {
    let worktree = FakeWorktree(prefix: "xcd format tool")

    func tool(key: String = "run") -> CommandTool {
        var tool = CommandTool(runner: RoutingRunner(fake: worktree.runner, realExecutables: ["sh"]), now: { Date(timeIntervalSince1970: 1_790_040_000) })
        tool.key = key
        return tool
    }

    func context() throws -> WorktreeContext {
        try worktree.context("version: 1\nproject: App.xcodeproj\nformat:\n  run: ./scripts/format.sh\n", container: "App.xcodeproj")
    }

    func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: worktree.root + "/" + path))
    }

    @Test func aFormatCommandRunsAsTheLintOneDoesUnderItsOwnName() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        let result = try await tool().run(#"printf '%s\n' "$0" "$@""#, section: "format", files: ["My File.swift"], in: ctx)
        #expect(result.exitCode == 0 && result.output == "xcd-format\nMy File.swift\n")
        #expect(result.log.hasPrefix(worktree.root + "/.xcdev/logs/") && result.log.hasSuffix("-format.log"))
    }

    /// Each message names the setting that holds the command, so a person knows which line of .xcdev.yml to look at.
    @Test func aCheckCommandIsNamedByItsOwnSetting() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        let missing = await #expect(throws: XcdError.self) {
            _ = try await tool(key: "check").run("./scripts/check.sh \"$@\"", section: "format", files: ["A.swift"], in: ctx)
        }
        #expect(missing?.code == .subprocessFailed && missing?.message == "the project's format check command could not be run (exit 127)")
        #expect(missing?.next == "its command was not found; check format.check in .xcdev.yml (paths are relative to the worktree root)")
        let tooMany = await #expect(throws: XcdError.self) {
            _ = try await tool(key: "check").run("true", section: "format", files: Array(repeating: String(repeating: "a", count: 99), count: 2_501), in: ctx)
        }
        #expect(tooMany?.message == "2501 files are too many to hand to format.check on one command line")
        #expect(CommandTool.unnamedFilesNote("./scripts/check.sh", section: "format", files: 2, key: "check")
                == #"format.check has no "$@", so the command did not get the 2 files in scope; write "$@" where the files go"#)
        let unfound = await #expect(throws: XcdError.self) { _ = try await tool().run("./scripts/format.sh", section: "format", files: [], in: ctx) }
        #expect(unfound?.message == "the project's format command could not be run (exit 127)")
        #expect(unfound?.next == "its command was not found; check format.run in .xcdev.yml (paths are relative to the worktree root)")
    }

    @Test func aSlowCheckIsNamedWhenItIsStopped() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        var slow = CommandTool(runner: RoutingRunner(fake: worktree.runner, realExecutables: ["sh"]), timeout: .milliseconds(300))
        slow.key = "check"
        let error = await #expect(throws: XcdError.self) { _ = try await slow.run("sleep 30; touch finished", section: "format", files: [], in: ctx) }
        #expect(error?.code == .timeout && error?.message == "the project's format check command timed out after 0.3s")
        #expect(error?.next == "make format.check finish sooner, or name paths to give it fewer files")
        #expect(!FileManager.default.fileExists(atPath: worktree.root + "/finished"))
    }

    /// A project's command says nothing about what it rewrote: xcd reads the files before and after.
    @Test func theFilesACommandRewroteAreTheOnesWhoseBytesDiffer() async throws {
        defer { worktree.remove() }
        let ctx = try context()
        for name in ["A.swift", "B.swift", "C.swift", "D.swift"] { try write("let x=1\n", to: name) }
        let stamps = FileStamps(of: ["A.swift", "B.swift", "C.swift", "D.swift", "E.swift"], in: worktree.root)
        #expect(stamps.changed(in: worktree.root).isEmpty)
        let command = "printf 'let x = 1\\n' > B.swift; printf 'let x=1\\n' > C.swift; rm D.swift; printf 'new\\n' > E.swift; touch A.swift"
        #expect(try await tool().run(command, section: "format", files: [], in: ctx).exitCode == 0)
        #expect(stamps.changed(in: worktree.root) == ["B.swift", "D.swift", "E.swift"])      // C was written again with the same bytes
    }
}
