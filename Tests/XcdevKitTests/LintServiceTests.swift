import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd lint` from its options to its report. Git and /bin/sh are real;
/// SwiftLint is `FakeSwiftLint`.
@Suite struct LintServiceTests {
    static let swiftlint = "version: 1\nproject: App.xcodeproj\nlint:\n  tool: swiftlint\n"

    let fake = FakeProcessRunner()
    let linter = FakeSwiftLint()

    /// `main` holds A.swift with one `print`, B.swift with none, and Docs/notes.txt. Branch `work` is checked out,
    /// and a file named `swiftlint` that can be run sits in `<base>/bin`.
    func project(_ config: String = LintServiceTests.swiftlint) throws -> (project: TempProject, fork: String) {
        let project = try TempProject.make(config: config)
        try project.write("func a() {\n    print(\"a\")\n}\n", to: "Sources/App/A.swift")
        try project.write("func b() {}\n", to: "Sources/App/B.swift")
        try project.write("notes\n", to: "Docs/notes.txt")
        let fork = try project.commit("Base")
        try project.git("checkout", "-q", "-b", "work")
        try project.write("#!/bin/sh\n", to: "bin/swiftlint", in: project.base)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.base + "/bin/swiftlint")
        return (project, fork)
    }

    func runner() -> RoutingRunner { RoutingRunner(fake: fake, realExecutables: ["git", "sh"]) }

    func service(_ project: TempProject, from directory: String? = nil, path: String? = nil) -> LintService {
        linter.install(on: fake)
        return LintService(runner: runner(), locator: ToolLocator(environment: ["PATH": path ?? project.base + "/bin"], extraFolders: []),
                           currentDirectory: directory ?? project.root, interrupts: Interrupts(), output: .json,
                           now: { Date(timeIntervalSince1970: 1_790_040_000) })
    }

    func context(_ project: TempProject) async throws -> WorktreeContext {
        try await WorktreeService(runner: runner(), globalPaths: GlobalPaths(base: project.home)).open(from: project.root)
    }

    /// The change every test starts from: A.swift gains a second `print`, and C.swift is new with an `abort`.
    func change(_ project: TempProject) throws {
        try project.write("func a() {\n    print(\"a\")\n    print(\"again\")\n}\n", to: "Sources/App/A.swift")
        try project.write("func c() {\n    abort(\"c\")\n}\n", to: "Sources/App/C.swift")
    }

    @Test func aProjectThatNeverSaidIsNotConfigured() async throws {
        let (project, _) = try project("version: 1\nproject: App.xcodeproj\n")
        defer { project.remove() }
        let ctx = try await context(project)
        let error = await #expect(throws: XcdError.self) { _ = try await service(project).lint(LintOptions(), in: ctx) }
        #expect(error?.code == .notConfigured && error?.code.exitCode == 2)
        #expect(error?.message == "lint is not set up for this project")
        #expect(error?.next == "add `lint: { tool: swiftlint }` to .xcdev.yml, or `lint: { tool: none }` if the project has no linter")

        try project.write("included: [Sources]\n", to: ".swiftlint.yml")
        let found = await #expect(throws: XcdError.self) { _ = try await service(project).lint(LintOptions(all: true), in: ctx) }
        #expect(found?.next == ".swiftlint.yml found: run `xcd doctor --fix`, or add `lint: { tool: swiftlint }` to .xcdev.yml")
        #expect(fake.calls.isEmpty)
    }

    @Test func aProjectWithNoLinterSucceedsAndRunsNothing() async throws {
        let (project, _) = try project("version: 1\nproject: App.xcodeproj\nlint:\n  tool: none\n")
        defer { project.remove() }
        try change(project)
        let ctx = try await context(project)
        let report = try await service(project).lint(LintOptions(), in: ctx)
        #expect(report.failure == nil && report.tool == "none")
        #expect(report.text == "lint: no linter is set up  (lint.tool is none)")
        try project.write("included: [Sources]\n", to: ".swiftlint.yml")
        #expect(try await service(project).lint(LintOptions(), in: ctx).notes
                == [".swiftlint.yml found: set `lint.tool: swiftlint` in .xcdev.yml to have `xcd lint` use it"])
        #expect(fake.calls.isEmpty)
    }

    @Test func theDefaultScopeShowsWhatTheChangeIntroduced() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        try change(project)
        let ctx = try await context(project)
        let report = try await service(project).lint(LintOptions(), in: ctx)

        #expect(report.tool == "swiftlint" && report.scope == .lines && report.files == 2)
        #expect(report.base == "main" && report.baseCommit == fork)
        #expect(report.findings.map(\.text) == [
            "Sources/App/A.swift:3:5: warning: no_print is not allowed (no_print)",
            "Sources/App/C.swift:2:5: error: no_abort is not allowed (no_abort)",
        ])
        #expect(report.older == 1)
        #expect(report.failure?.code == .lintFailed)                           // the new file's finding is an error
        #expect(report.text.hasPrefix("lint: 2 new findings  tool=swiftlint  files=2  base=main  0.0s\n"))
        let log = try #require(report.log)
        #expect(log.hasPrefix(project.root + "/.xcdev/logs/") && log.hasSuffix("-lint.log"))
        #expect(try String(contentsOfFile: log, encoding: .utf8).components(separatedBy: "$ swiftlint lint").count == 3)
        #expect(fake.calls.first { $0.argv.first == "swiftlint" }?.executable == project.base + "/bin/swiftlint")
    }

    @Test func filesShowsEveryFindingInTheChangedFiles() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        try change(project)
        let ctx = try await context(project)
        let report = try await service(project).lint(LintOptions(files: true), in: ctx)
        #expect(report.scope == .files && report.older == 0 && report.base == "main")
        #expect(report.findings.map { "\($0.file):\($0.line ?? 0)" } == ["Sources/App/A.swift:2", "Sources/App/A.swift:3", "Sources/App/C.swift:2"])
        #expect(linter.runs.count == 1)
        #expect(report.text.hasPrefix("lint: 3 findings  tool=swiftlint  files=2  base=main  "))
    }

    /// `--all` is every Swift file git knows. The worktree's own `.xcdev/` folder ignores itself, so nothing in
    /// it is ever handed to the linter, however much it holds.
    @Test func allLintsTheProjectAndNothingUnderTheStateFolder() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        try change(project)
        let ctx = try await context(project)                                   // opening the worktree makes .xcdev/
        try project.write("func x() { print(1) }\n", to: ".xcdev/SourcePackages/checkouts/Dep/Sources/X.swift")
        try project.write("func y() { print(1) }\n", to: ".xcdev/DerivedData/Build/Y.swift")
        let report = try await service(project).lint(LintOptions(all: true), in: ctx)

        #expect(report.scope == .all && report.base == nil && report.baseCommit == nil && report.files == 3)
        #expect(linter.runs.count == 1)
        #expect(linter.runs.first?.swiftFiles == ["Sources/App/A.swift", "Sources/App/B.swift", "Sources/App/C.swift"])
        #expect(report.findings.count == 3)
        #expect(report.text.hasPrefix("lint: 3 findings  tool=swiftlint  files=3  0.0s\n"))
    }

    @Test func pathsNarrowTheScopeAndAreReadFromTheCurrentDirectory() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        try change(project)
        let ctx = try await context(project)
        let one = try await service(project, from: project.root + "/Sources").lint(LintOptions(paths: ["App/C.swift"]), in: ctx)
        #expect(one.files == 1 && one.findings.map(\.file) == ["Sources/App/C.swift"])
        let none = try await service(project).lint(LintOptions(paths: ["Docs"]), in: ctx)
        #expect(none.failure == nil && none.files == 0)
        #expect(none.text == "lint: no Swift files changed since main under Docs  tool=swiftlint\nnote: `xcd lint --all` lints the whole project")
    }

    @Test func nothingChangedIsNotAnErrorAndRunsNoLinter() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        let ctx = try await context(project)
        let report = try await service(project, path: "/nowhere").lint(LintOptions(), in: ctx)    // not even looked for
        #expect(report.failure == nil)
        #expect(report.text == "lint: no Swift files changed since main  tool=swiftlint\nnote: `xcd lint --all` lints the whole project")
        #expect(!fake.calls.contains { $0.argv.first == "swiftlint" })
    }

    @Test func twoScopesOrABaseWithAllAreUsageErrors() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        let ctx = try await context(project)
        let both = await #expect(throws: XcdError.self) { _ = try await service(project).lint(LintOptions(files: true, all: true), in: ctx) }
        #expect(both?.code == .usage && both?.message == "--files and --all are two scopes")
        let based = await #expect(throws: XcdError.self) { _ = try await service(project).lint(LintOptions(all: true, base: "main"), in: ctx) }
        #expect(based?.code == .usage && based?.message == "--base has no meaning with --all, which compares with nothing")
        let outside = await #expect(throws: XcdError.self) { _ = try await service(project).lint(LintOptions(paths: ["/etc"]), in: ctx) }
        #expect(outside?.code == .usage)
    }

    @Test func aLinterThatIsNotInstalledIsToolMissing() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        try change(project)
        let ctx = try await context(project)
        let error = await #expect(throws: XcdError.self) { _ = try await service(project, path: "/nowhere").lint(LintOptions(), in: ctx) }
        #expect(error?.code == .toolMissing && error?.code.exitCode == 3)
        #expect(error?.next == "brew install swiftlint, or set lint.path in .xcdev.local.yml")
    }

    @Test func theFlagAndTheWorktreesRecordedBaseChooseWhatIsCompared() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        try change(project)
        let committed = try project.commit("Work")
        try project.git("branch", "develop", committed)
        var ctx = try await context(project)
        ctx.state.base = "develop"                                             // as `xcd worktree create --from develop` records it
        let recorded = try await service(project).lint(LintOptions(), in: ctx)
        #expect(recorded.base == "develop" && recorded.baseCommit == committed && recorded.files == 0)
        let flagged = try await service(project).lint(LintOptions(base: "main"), in: ctx)
        #expect(flagged.base == "main" && flagged.files == 2)
        #expect(flagged.findings.map(\.text) == [                              // measured from the fork point, not from HEAD
            "Sources/App/A.swift:3:5: warning: no_print is not allowed (no_print)",
            "Sources/App/C.swift:2:5: error: no_abort is not allowed (no_abort)",
        ])
        #expect(flagged.older == 1)
    }

    @Test func theProjectsArgumentsAndPathReachSwiftLint() async throws {
        let config = Self.swiftlint + "  args: [\"--strict\"]\n  path: tools/swiftlint\n"
        let (project, _) = try project(config)
        defer { project.remove() }
        try change(project)
        try project.write("#!/bin/sh\n", to: "tools/swiftlint")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.root + "/tools/swiftlint")
        let ctx = try await context(project)
        _ = try await service(project, path: "/nowhere").lint(LintOptions(paths: ["Sources"], files: true), in: ctx)
        let call = try #require(fake.calls.first { $0.argv.first == "swiftlint" })
        #expect(call.executable == project.root + "/tools/swiftlint")
        #expect(call.arguments == ["lint", "--quiet", "--reporter", "json", "--no-cache", "--strict"])
    }

    @Test func whatSwiftLintWarnsAboutIsShownAsNotes() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        try change(project)
        let ctx = try await context(project)
        let noisy = FakeSwiftLint(stderr: (1...5).map { "warning: line \($0)\n" }.joined())
        let service = service(project)
        noisy.install(on: fake)
        let report = try await service.lint(LintOptions(), in: ctx)
        #expect(report.notes == ["swiftlint: warning: line 1", "swiftlint: warning: line 2", "swiftlint: warning: line 3",
                                 "swiftlint: 2 more lines are in the log"])
        #expect(report.text.contains("\nlog: \(project.root)/.xcdev/logs/"))
    }

    @Test func aProjectsOwnCommandGetsTheChangedFilesWhole() async throws {
        let (project, fork) = try project("version: 1\nproject: App.xcodeproj\nlint:\n  run: printf '%s\\n' checked \"$@\"\n")
        defer { project.remove() }
        try change(project)
        let ctx = try await context(project)
        let report = try await service(project).lint(LintOptions(), in: ctx)
        #expect(report.tool == "printf '%s\\n' checked \"$@\"" && report.scope == .files)      // a command sees whole files
        #expect(report.base == "main" && report.baseCommit == fork && report.files == 2)
        #expect(report.exitCode == 0 && report.failure == nil)
        #expect(report.output == "checked\nSources/App/A.swift\nSources/App/C.swift\n")
        #expect(report.text.hasPrefix("lint: passed  tool=printf '%s\\n' checked \"$@\"  files=2  base=main  0.0s\nchecked\n"))
        #expect(report.notes.isEmpty)
        #expect(!fake.calls.contains { $0.argv.first == "swiftlint" })
    }

    /// A command written as a YAML block (`run: |`) ends in a newline, which must not break the result's first line.
    @Test func aCommandWrittenAsABlockIsShownWithoutItsNewline() async throws {
        let (project, _) = try project("version: 1\nproject: App.xcodeproj\nlint:\n  run: |\n    echo checked \"$@\"\n")
        defer { project.remove() }
        try change(project)
        let ctx = try await context(project)
        #expect(ctx.config.lintSetup == .command("echo checked \"$@\"\n"))
        let report = try await service(project).lint(LintOptions(), in: ctx)
        #expect(report.tool == "echo checked \"$@\"")
        #expect(report.text.components(separatedBy: "\n").first == "lint: passed  tool=echo checked \"$@\"  files=2  base=main  0.0s")
        #expect(report.output == "checked Sources/App/A.swift Sources/App/C.swift\n")
    }

    /// A script of several lines is named by its first line, trimmed, and ` …`. All of it still runs.
    @Test func aCommandOfSeveralLinesIsShownByItsFirstLine() async throws {
        let (project, _) = try project("version: 1\nproject: App.xcodeproj\nlint:\n  run: |\n    echo one  \n    echo two \"$@\"\n")
        defer { project.remove() }
        try change(project)
        let ctx = try await context(project)
        #expect(ctx.config.lintSetup == .command("echo one  \necho two \"$@\"\n"))
        let report = try await service(project).lint(LintOptions(), in: ctx)
        #expect(report.tool == "echo one …")
        #expect(report.text.components(separatedBy: "\n").first == "lint: passed  tool=echo one …  files=2  base=main  0.0s")
        #expect(report.output == "one\ntwo Sources/App/A.swift Sources/App/C.swift\n")
    }

    @Test func aProjectsOwnCommandThatFailsIsLintFailed() async throws {
        let (project, _) = try project("version: 1\nproject: App.xcodeproj\nlint:\n  run: \"echo bad; exit 4 #\"\n")
        defer { project.remove() }
        try change(project)
        let ctx = try await context(project)
        let report = try await service(project).lint(LintOptions(), in: ctx)
        #expect(report.exitCode == 4 && report.output == "bad\n")
        #expect(report.failure?.code == .lintFailed && report.failure?.message == "the project's lint command exited 4")
    }

    /// With `--all` and no paths the command is handed no files and covers the project its own way.
    @Test func withAllAndNoPathsACommandGetsNoFiles() async throws {
        let (project, _) = try project("version: 1\nproject: App.xcodeproj\nlint:\n  run: echo files \"$@\"\n")
        defer { project.remove() }
        try change(project)
        let ctx = try await context(project)
        let whole = try await service(project).lint(LintOptions(all: true), in: ctx)
        #expect(whole.output == "files\n" && whole.scope == .all && whole.files == 3 && whole.base == nil)
        let narrowed = try await service(project).lint(LintOptions(paths: ["Sources/App/B.swift"], all: true), in: ctx)
        #expect(narrowed.output == "files Sources/App/B.swift\n" && narrowed.files == 1)
        #expect(whole.notes.isEmpty && narrowed.notes.isEmpty)
        let nothing = try await service(project).lint(LintOptions(paths: ["Docs"]), in: ctx)
        #expect(nothing.text.hasPrefix("lint: no Swift files changed since main under Docs  tool=echo files \"$@\"\n"))
    }

    /// xcd adds nothing to the command, so one with no `"$@"` gets no files. The result says so: such a command may
    /// cover the project its own way, or its author may have expected the files after it.
    @Test func aCommandThatDoesNotNameItsFilesRunsWithoutThemAndIsToldSo() async throws {
        let (project, _) = try project("version: 1\nproject: App.xcodeproj\nlint:\n  run: echo checked\n")
        defer { project.remove() }
        try change(project)
        let ctx = try await context(project)
        let report = try await service(project).lint(LintOptions(), in: ctx)
        #expect(report.output == "checked\n" && report.exitCode == 0 && report.files == 2)
        #expect(report.notes == [#"lint.run has no "$@", so the command did not get the 2 files in scope; write "$@" where the files go"#])
        #expect(report.text.hasPrefix("lint: passed  tool=echo checked  files=2  base=main  0.0s\nnote: lint.run has no \"$@\", "))
        let whole = try await service(project).lint(LintOptions(all: true), in: ctx)
        #expect(whole.output == "checked\n" && whole.notes.isEmpty)                  // with --all there are none to get
    }
}
