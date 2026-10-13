import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Linting the files in scope in scratch folders, and telling new findings from old. Git is
/// real; SwiftLint is `FakeSwiftLint`, which lints whatever the folder it runs in holds.
@Suite struct SwiftLintLinterTests {
    let fake = FakeProcessRunner()
    let swiftlint = FakeSwiftLint()

    /// `main` holds A.swift with one `print`, B.swift with none, a root config, and a nested one under Sources/App.
    func project() throws -> (project: TempProject, fork: String) {
        let project = try TempProject.make(config: "version: 1\nproject: App.xcodeproj\nlint:\n  tool: swiftlint\n")
        try project.write("func a() {\n    print(\"a\")\n}\n", to: "Sources/App/A.swift")
        try project.write("func b() {}\n", to: "Sources/App/B.swift")
        try project.write("included: [Sources]\n", to: ".swiftlint.yml")
        try project.write("disabled_rules: [todo]\n", to: "Sources/App/.swiftlint.yml")
        let fork = try project.commit("Base")
        try project.git("checkout", "-q", "-b", "work")
        return (project, fork)
    }

    func linter(_ project: TempProject, args: [String] = []) -> SwiftLintLinter {
        swiftlint.install(on: fake)
        let runner = RoutingRunner(fake: fake, realExecutables: ["git"])
        return SwiftLintLinter(tool: SwiftLintTool(runner: runner, executable: "/opt/homebrew/bin/swiftlint", args: args),
                               worktreeRoot: project.root, interrupts: Interrupts())
    }

    func changed(_ path: String) -> ScopedFile { ScopedFile(path: path, basePath: path) }

    @Test func withoutAForkPointEveryFindingIsShown() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        try project.write("func b() {\n    abort(\"b\")\n}\n", to: "Sources/App/B.swift")
        let result = try await linter(project).lint([changed("Sources/App/A.swift"), changed("Sources/App/B.swift")], against: nil)

        #expect(result.findings.map(\.text) == [
            "Sources/App/A.swift:2:5: warning: no_print is not allowed (no_print)",
            "Sources/App/B.swift:2:5: error: no_abort is not allowed (no_abort)",
        ])
        #expect(result.older == 0)
        #expect(swiftlint.runs.count == 1)
        #expect(swiftlint.runs.first?.swiftFiles == ["Sources/App/A.swift", "Sources/App/B.swift"])
        #expect(swiftlint.runs.first?.otherFiles == [".swiftlint.yml", "Sources/App/.swiftlint.yml"])
    }

    @Test func againstAForkPointOnlyWhatTheChangeIntroducedIsShown() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        let longer = "// A comment that moves everything down\nfunc a() {\n    print(\"a\")\n    print(\"again\")\n}\n"
            + String(repeating: "// filler\n", count: 8)
        try project.write(longer, to: "Sources/App/A.swift")
        let result = try await linter(project).lint([changed("Sources/App/A.swift"), changed("Sources/App/B.swift")], against: fork)

        #expect(result.findings.map(\.text) == [
            "Sources/App/A.swift:1: warning: File should contain 10 lines or less: currently contains 13 (file_length)",
            "Sources/App/A.swift:4:5: warning: no_print is not allowed (no_print)",
        ])
        #expect(result.older == 1)                                            // the print the base already had, now on line 3
        // The second run linted the base version of the one file that had findings.
        #expect(swiftlint.runs.count == 2)
        #expect(swiftlint.runs.last?.swiftFiles == ["Sources/App/A.swift"])
        #expect(swiftlint.runs.last?.texts["Sources/App/A.swift"] == "func a() {\n    print(\"a\")\n}\n")
    }

    /// The base version is linted with the config as it is now, so a rule the change turned on is applied to both.
    @Test func theBaseIsLintedWithTodaysConfig() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        try project.write("included: [Sources]\nopt_in_rules: [no_print]\n", to: ".swiftlint.yml")
        try project.write("func a() {\n    print(\"a\")\n    print(\"b\")\n}\n", to: "Sources/App/A.swift")
        _ = try await linter(project).lint([changed("Sources/App/A.swift")], against: fork)
        #expect(swiftlint.runs.last?.texts[".swiftlint.yml"] == "included: [Sources]\nopt_in_rules: [no_print]\n")
        #expect(swiftlint.runs.last?.otherFiles == [".swiftlint.yml", "Sources/App/.swiftlint.yml"])
    }

    @Test func aRenamedFileIsComparedWithTheVersionAtItsOldPath() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        try FileManager.default.createDirectory(atPath: project.root + "/Sources/Core", withIntermediateDirectories: true)
        try project.git("mv", "Sources/App/A.swift", "Sources/Core/Renamed.swift")
        try project.write("func a() {\n    print(\"a\")\n    abort(\"new\")\n}\n", to: "Sources/Core/Renamed.swift")
        let file = ScopedFile(path: "Sources/Core/Renamed.swift", basePath: "Sources/App/A.swift")
        let result = try await linter(project).lint([file], against: fork)

        #expect(result.findings.map(\.text) == ["Sources/Core/Renamed.swift:3:5: error: no_abort is not allowed (no_abort)"])
        #expect(result.older == 1)
        #expect(swiftlint.runs.last?.swiftFiles == ["Sources/App/A.swift"])       // the base folder holds the old path
        #expect(swiftlint.runs.last?.otherFiles == [".swiftlint.yml", "Sources/App/.swiftlint.yml"])
    }

    @Test func aNewFilesFindingsAreAllNewAndTheBaseIsNotLintedForIt() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        try project.write("func c() {\n    print(\"c\")\n}\n", to: "Sources/App/C.swift")
        let result = try await linter(project).lint([ScopedFile(path: "Sources/App/C.swift", basePath: nil), changed("Sources/App/B.swift")],
                                                    against: fork)
        #expect(result.findings.map(\.file) == ["Sources/App/C.swift"])
        #expect(result.older == 0)
        #expect(swiftlint.runs.count == 1)                                     // no file with findings has a base version
    }

    @Test func findingsComeInPathLineAndColumnOrder() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        try project.write("func b() { print(1); abort(\"x\") }\nfunc c() { print(2) }\n", to: "Sources/App/B.swift")
        let result = try await linter(project).lint([changed("Sources/App/B.swift"), changed("Sources/App/A.swift")], against: nil)
        #expect(result.findings.map { "\($0.file):\($0.line ?? 0):\($0.column ?? 0)" } == [
            "Sources/App/A.swift:2:5", "Sources/App/B.swift:1:12", "Sources/App/B.swift:1:22", "Sources/App/B.swift:2:12",
        ])
    }

    /// A file that was in scope and is gone by the time it is read is left out; the rest is linted.
    @Test func aFileThatVanishedIsLeftOut() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        let result = try await linter(project).lint([changed("Sources/App/A.swift"), changed("Sources/App/Gone.swift")], against: fork)
        #expect(swiftlint.runs.first?.swiftFiles == ["Sources/App/A.swift"])
        #expect(result.findings.isEmpty && result.older == 1)
    }

    /// The folder holds each file's bytes as they are, so SwiftLint sees what it would see in the project. A file
    /// that is not UTF-8 is one it skips; a copy with its bad bytes replaced would be linted instead.
    @Test func aFileIsCopiedByteForByte() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        let latin = Data([0x2F, 0x2F, 0x20, 0x63, 0x61, 0x66, 0xE9, 0x0A]) + Data("func latin() {\n    print(1)\n}\n".utf8)     // "// café" in Latin-1
        try latin.write(to: URL(fileURLWithPath: project.root + "/Sources/App/Latin.swift"))
        try project.write("func a() {\r\n    print(\"a\")\r\n}\r\n", to: "Sources/App/A.swift")
        let files = [changed("Sources/App/A.swift"), ScopedFile(path: "Sources/App/Latin.swift", basePath: nil)]
        let result = try await linter(project).lint(files, against: fork)
        #expect(swiftlint.runs.first?.bytes["Sources/App/Latin.swift"] == latin)
        #expect(swiftlint.runs.first?.texts["Sources/App/A.swift"] == "func a() {\r\n    print(\"a\")\r\n}\r\n")
        #expect(result.findings.isEmpty && result.older == 1)                // CRLF now, LF at the base: the same finding
    }

    /// Ctrl-C ends xcd before `lint` gets to remove its folder, so a cleanup on its `Interrupts` removes it, registered
    /// while SwiftLint runs.
    @Test func ctrlCWhileSwiftLintRunsRemovesTheFolder() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        let interrupts = Interrupts(report: { _ in /* the handler's line is not what this test reads */ })
        let goneAtOnce = Shared<[Bool]>([])
        fake.stub(["swiftlint"]) { invocation in
            _ = interrupts.handle(SIGINT)                                    // what Ctrl-C runs, minus the exit
            goneAtOnce.change { $0.append(!FileManager.default.fileExists(atPath: invocation.workingDirectory ?? "/")) }
            return ProcessOutput(stdout: "[\n\n]\n")
        }
        let runner = RoutingRunner(fake: fake, realExecutables: ["git"])
        let linter = SwiftLintLinter(tool: SwiftLintTool(runner: runner, executable: "/opt/homebrew/bin/swiftlint", args: []),
                                     worktreeRoot: project.root, interrupts: interrupts)
        _ = try? await linter.lint([changed("Sources/App/A.swift")], against: nil)
        #expect(goneAtOnce.value == [true])
    }

    /// Ctrl-C before or while a folder is filled: the linter's folders go through its `Interrupts`, so nothing more
    /// is written and SwiftLint is not started on half a folder.
    @Test func ctrlCBeforeTheFolderIsFilledStartsNoSwiftLint() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        let interrupts = Interrupts(report: { _ in /* the handler's line is not what this test reads */ })
        swiftlint.install(on: fake)
        let runner = RoutingRunner(fake: fake, realExecutables: ["git"])
        let linter = SwiftLintLinter(tool: SwiftLintTool(runner: runner, executable: "/opt/homebrew/bin/swiftlint", args: []),
                                     worktreeRoot: project.root, interrupts: interrupts)
        _ = interrupts.handle(SIGINT)                                        // what Ctrl-C runs, minus the exit
        let error = await #expect(throws: XcdError.self) { _ = try await linter.lint([changed("Sources/App/A.swift")], against: nil) }
        #expect(error?.message.hasPrefix("xcd was interrupted") == true)
        #expect(swiftlint.runs.isEmpty)
    }

    @Test func theFoldersAreGoneAfterwardsAndAlsoWhenSwiftLintFails() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        try project.write("func a() {\n    print(\"a\")\n    print(\"b\")\n}\n", to: "Sources/App/A.swift")
        _ = try await linter(project).lint([changed("Sources/App/A.swift")], against: fork)
        #expect(swiftlint.runs.count == 2)
        for run in swiftlint.runs {
            #expect(!FileManager.default.fileExists(atPath: run.folder))
            #expect(!Paths.canonical(run.folder).hasPrefix(project.root))       // and it was never inside the worktree
        }

        let folders = Shared<[String]>([])
        fake.stub(["swiftlint"]) { invocation in
            folders.change { $0.append(invocation.workingDirectory ?? "") }
            return ProcessOutput(exitCode: 1, stdout: "", stderr: "Fatal error\n")
        }
        let runner = RoutingRunner(fake: fake, realExecutables: ["git"])
        let broken = SwiftLintLinter(tool: SwiftLintTool(runner: runner, executable: "/opt/homebrew/bin/swiftlint", args: []),
                                     worktreeRoot: project.root, interrupts: Interrupts())
        let error = await #expect(throws: XcdError.self) { _ = try await broken.lint([changed("Sources/App/A.swift")], against: fork) }
        #expect(error?.code == .subprocessFailed)
        #expect(folders.value.count == 1 && !FileManager.default.fileExists(atPath: folders.value.first ?? "/"))
    }

    @Test func whatSwiftLintSaidAndRanIsKept() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        let noisy = FakeSwiftLint(stderr: "warning: Unknown rule\n")
        noisy.install(on: fake)
        try project.write("func a() {\n    print(\"a\")\n    print(\"b\")\n}\n", to: "Sources/App/A.swift")
        let runner = RoutingRunner(fake: fake, realExecutables: ["git"])
        let linter = SwiftLintLinter(tool: SwiftLintTool(runner: runner, executable: "/opt/homebrew/bin/swiftlint", args: ["--strict"]),
                                     worktreeRoot: project.root, interrupts: Interrupts())
        let result = try await linter.lint([changed("Sources/App/A.swift")], against: fork)
        #expect(result.notes == ["warning: Unknown rule"])                     // once, though SwiftLint ran twice
        #expect(result.transcript.components(separatedBy: "$ swiftlint lint --quiet --reporter json --no-cache --strict").count == 3)
    }
}
