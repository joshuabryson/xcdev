import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// A project for the `xcd format` tests, with a change on a branch. Git is real.
struct FormatProject {
    static let swiftFormat = "version: 1\nproject: App.xcodeproj\nformat:\n  tool: swiftformat\n"
    static let appleSwiftFormat = "version: 1\nproject: App.xcodeproj\nformat:\n  tool: swift-format\n"
    /// A.swift on `main`. Line 2 ends in blanks and line 5 starts with tabs: both are as the formatter would not
    /// leave them, and both were there before the change.
    static let base = "struct A {\n    let a = 1   \n    let b = 2\n    func f() {\n\t\tlet c = 3\n    }\n    let d = 4\n}\n"

    let project: TempProject
    let fork: String
    let fake = FakeProcessRunner()

    var root: String { project.root }
    /// Where the stand-in `swiftformat` is, for PATH.
    var bin: String { project.base + "/bin" }
    /// What `xcrun --find swift-format` answers.
    var inXcode: String { project.base + "/Xcode.app/Contents/Developer/Toolchains/usr/bin/swift-format" }

    /// `main` holds A.swift (see `base`), B.swift, which is as the formatter wants it, and Docs/notes.txt. Branch
    /// `work` is checked out. Files that can be run stand where the two formatters are looked for.
    init(_ config: String = FormatProject.swiftFormat) throws {
        project = try TempProject.make(config: config)
        try project.write(Self.base, to: "Sources/App/A.swift")
        try project.write("func b() {}\n", to: "Sources/App/B.swift")
        try project.write("notes\n", to: "Docs/notes.txt")
        fork = try project.commit("Base")
        try project.git("checkout", "-q", "-b", "work")
        for tool in [bin + "/swiftformat", inXcode] {
            try project.write("#!/bin/sh\n", to: String(tool.dropFirst(project.base.count + 1)), in: project.base)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)
        }
        fake.stub(["xcrun", "--find", "swift-format"], stdout: inXcode + "\n")
    }

    /// The change every test starts from: line 7 of A.swift is edited and ends in blanks, and C.swift is new, with a
    /// tab and no newline at its end.
    func change() throws {
        try project.write(Self.base.replacingOccurrences(of: "    let d = 4\n", with: "    let d = 40  \n"), to: "Sources/App/A.swift")
        try project.write("struct C {\n\tlet c = 1\n}", to: "Sources/App/C.swift")
    }

    var runner: RoutingRunner { RoutingRunner(fake: fake, realExecutables: ["git", "sh"]) }

    func service(_ formatters: FakeFormatters, from directory: String? = nil, path: String? = nil) -> FormatService {
        formatters.install(on: fake)
        return FormatService(QualityHost(runner: runner, locator: ToolLocator(environment: ["PATH": path ?? bin], extraFolders: []),
                                         currentDirectory: directory ?? root, interrupts: Interrupts(), output: .json,
                                         now: { Date(timeIntervalSince1970: 1_790_040_000) }))
    }

    func context() async throws -> WorktreeContext {
        try await WorktreeService(runner: runner, globalPaths: GlobalPaths(base: project.home)).open(from: root)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOfFile: root + "/" + path, encoding: .utf8)
    }
}

/// `xcd format` with a named formatter, from its options to its report and the files on disk. Git is real; the
/// formatters are `FakeFormatters`.
@Suite struct FormatServiceTests {
    let formatters = FakeFormatters()
    /// A.swift after the change, with only its changed line 7 formatted.
    static let lineSeven = FormatProject.base.replacingOccurrences(of: "    let d = 4\n", with: "    let d = 40\n")
    /// A.swift after the change, formatted whole.
    static let whole = "struct A {\n    let a = 1\n    let b = 2\n    func f() {\n        let c = 3\n    }\n    let d = 40\n}\n"

    @Test func aProjectThatNeverSaidIsNotConfigured() async throws {
        let project = try FormatProject("version: 1\nproject: App.xcodeproj\n")
        defer { project.project.remove() }
        let ctx = try await project.context()
        func next() async -> String? {
            await #expect(throws: XcdError.self) { _ = try await project.service(formatters).format(FormatOptions(all: true), in: ctx) }?.next
        }
        let error = await #expect(throws: XcdError.self) { _ = try await project.service(formatters).format(FormatOptions(), in: ctx) }
        #expect(error?.code == .notConfigured && error?.code.exitCode == 2 && error?.message == "format is not set up for this project")
        #expect(error?.next == "add `format: { tool: swift-format }` to .xcdev.yml for Xcode's formatter, which indents with 2 spaces unless the project adds a .swift-format file, or `format: { tool: none }` if the project has no formatter")
        try project.project.write("--indent 4\n", to: ".swiftformat")
        #expect(await next() == ".swiftformat found: run `xcd doctor --fix`, or add `format: { tool: swiftformat }` to .xcdev.yml")
        try project.project.write("{}\n", to: ".swift-format")
        #expect(await next() == ".swift-format and .swiftformat found: add `format: { tool: swift-format }` or `format: { tool: swiftformat }` to .xcdev.yml, whichever the project uses")
        #expect(project.fake.calls.isEmpty)
    }

    @Test func aProjectWithNoFormatterSucceedsAndRunsNothing() async throws {
        let project = try FormatProject("version: 1\nproject: App.xcodeproj\nformat:\n  tool: none\n")
        defer { project.project.remove() }
        try project.change()
        let ctx = try await project.context()
        let report = try await project.service(formatters).format(FormatOptions(check: true), in: ctx)
        #expect(report.failure == nil && report.tool == "none" && report.check)
        #expect(report.text == "format: no formatter is set up  (format.tool is none)")
        try project.project.write("{}\n", to: ".swift-format")
        #expect(try await project.service(formatters).format(FormatOptions(), in: ctx).notes
                == [".swift-format found: set `format.tool: swift-format` in .xcdev.yml to have `xcd format` use it"])
        #expect(project.fake.calls.isEmpty)
    }

    @Test func theDefaultScopeReformatsOnlyTheLinesTheChangeTouched() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        try project.change()
        let ctx = try await project.context()
        let report = try await project.service(formatters).format(FormatOptions(), in: ctx)

        #expect(try project.read("Sources/App/A.swift") == Self.lineSeven)           // lines 2 and 5 are as they were
        #expect(try project.read("Sources/App/C.swift") == "struct C {\n    let c = 1\n}\n")  // a new file is formatted whole
        #expect(report.tool == "swiftformat" && report.scope == .lines && report.files == 2 && !report.check)
        #expect(report.base == "main" && report.baseCommit == project.fork)
        #expect(report.changed == [FormatReport.Changed(file: "Sources/App/A.swift", lines: [LineRange(7, 7)]),
                                   FormatReport.Changed(file: "Sources/App/C.swift", lines: [LineRange(2, 3)])])
        #expect(report.failure == nil && report.failed.isEmpty && report.notes.isEmpty)
        #expect(report.text == """
        format: 2 files reformatted  tool=swiftformat  files=2  base=main  0.0s
        Sources/App/A.swift  line 7
        Sources/App/C.swift  lines 2-3
        """)
        #expect(formatters.runs.map { "\($0.file.dropFirst(project.root.count + 1)) \($0.ranges)" }.sorted()
                == ["Sources/App/A.swift [[7, 7]]", "Sources/App/C.swift []"])
        #expect(project.fake.calls.first { $0.argv.first == "swiftformat" }?.executable == project.bin + "/swiftformat")
        let log = try #require(report.log)
        #expect(log.hasPrefix(project.root + "/.xcdev/logs/") && log.hasSuffix("-format.log"))
        #expect(try String(contentsOfFile: log, encoding: .utf8).components(separatedBy: "$ swiftformat stdin").count == 3)
    }

    @Test func filesReformatsTheChangedFilesWhole() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        try project.change()
        let ctx = try await project.context()
        let report = try await project.service(formatters).format(FormatOptions(files: true), in: ctx)
        #expect(try project.read("Sources/App/A.swift") == Self.whole)
        #expect(report.scope == .files && report.base == "main" && report.files == 2)
        #expect(report.changed.first == FormatReport.Changed(file: "Sources/App/A.swift", lines: [LineRange(2, 2), LineRange(5, 5), LineRange(7, 7)]))
        #expect(formatters.runs.allSatisfy { $0.ranges.isEmpty } && formatters.runs.count == 2)
    }

    /// `--all` is every Swift file git knows. The worktree's own `.xcdev/` folder ignores itself, so nothing in it
    /// is ever handed to a formatter, however much it holds.
    @Test func allReformatsTheProjectAndNothingUnderTheStateFolder() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        try project.change()
        let ctx = try await project.context()                                    // opening the worktree makes .xcdev/
        try project.project.write("func x() {}   \n", to: ".xcdev/SourcePackages/checkouts/Dep/Sources/X.swift")
        let report = try await project.service(formatters).format(FormatOptions(all: true), in: ctx)

        #expect(report.scope == .all && report.base == nil && report.baseCommit == nil && report.files == 3)
        #expect(formatters.runs.map { String($0.file.dropFirst(project.root.count + 1)) }.sorted()
                == ["Sources/App/A.swift", "Sources/App/B.swift", "Sources/App/C.swift"])
        #expect(report.changed.map(\.file) == ["Sources/App/A.swift", "Sources/App/C.swift"])     // B was as the formatter wants it
        #expect(try project.read(".xcdev/SourcePackages/checkouts/Dep/Sources/X.swift") == "func x() {}   \n")
        #expect(report.text.hasPrefix("format: 2 files reformatted  tool=swiftformat  files=3  0.0s\n"))
    }

    @Test func aCheckWritesNothingAndFailsWhenSomethingWouldChange() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        try project.change()
        let changed = (a: try project.read("Sources/App/A.swift"), c: try project.read("Sources/App/C.swift"))
        let ctx = try await project.context()
        let report = try await project.service(formatters).format(FormatOptions(check: true), in: ctx)
        #expect(try project.read("Sources/App/A.swift") == changed.a && project.read("Sources/App/C.swift") == changed.c)
        #expect(report.check && report.failure?.code == .formatFailed && report.failure?.code.exitCode == 1)
        #expect(Renderer.report(report, command: "format", format: .text) == """
        format: 2 files need formatting  tool=swiftformat  files=2  base=main  0.0s
        Sources/App/A.swift  line 7
        Sources/App/C.swift  lines 2-3
        next: run `xcd format` to reformat them
        """)
        // After `xcd format`, the same check passes.
        _ = try await project.service(formatters).format(FormatOptions(), in: ctx)
        let again = try await project.service(formatters).format(FormatOptions(check: true), in: ctx)
        #expect(again.failure == nil && again.text == "format: nothing to reformat  tool=swiftformat  files=2  base=main  0.0s")
    }

    /// Apple's swift-format is the one in the worktree's Xcode. It reads each file itself and takes every range of
    /// a file in one run.
    @Test func applesFormatterIsFoundInTheWorktreesXcodeAndGetsAFilesRangesAtOnce() async throws {
        let project = try FormatProject(FormatProject.appleSwiftFormat)
        defer { project.project.remove() }
        try project.change()
        try project.project.write(FormatProject.base.replacingOccurrences(of: "    let b = 2\n", with: "    let b = 20  \n")
            .replacingOccurrences(of: "    let d = 4\n", with: "    let d = 40  \n"), to: "Sources/App/A.swift")
        var ctx = try await project.context()
        ctx.state.xcode = XcodeInstall(path: "/Applications/Xcode-27.app", version: "27.0", build: "27A1")
        let report = try await project.service(formatters, path: "/nowhere").format(FormatOptions(), in: ctx)

        #expect(report.tool == "swift-format" && report.changed.first?.lines == [LineRange(3, 3), LineRange(7, 7)])
        let found = try #require(project.fake.calls.first { $0.argv.first == "xcrun" })
        #expect(found.environment == ["DEVELOPER_DIR": "/Applications/Xcode-27.app/Contents/Developer"])
        let run = try #require(project.fake.calls.first { $0.argv.first == "swift-format" && $0.arguments.contains("--lines") })
        #expect(run.executable == project.inXcode && run.workingDirectory == project.root)
        #expect(run.arguments == ["format", "--lines", "3:3", "--lines", "7:7", project.root + "/Sources/App/A.swift"])
        #expect(formatters.runs.allSatisfy { $0.tool == "swift-format" && $0.inputFile == nil })
    }

    @Test func aFormatterThatIsNotInstalledIsToolMissingOnceThereIsSomethingToFormat() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        let ctx = try await project.context()
        let nothing = try await project.service(formatters, path: "/nowhere").format(FormatOptions(), in: ctx)    // not even looked for
        #expect(nothing.failure == nil)
        #expect(nothing.text == "format: no Swift files changed since main  tool=swiftformat\nnote: `xcd format --all` formats the whole project")
        try project.change()
        let error = await #expect(throws: XcdError.self) { _ = try await project.service(formatters, path: "/nowhere").format(FormatOptions(), in: ctx) }
        #expect(error?.code == .toolMissing && error?.code.exitCode == 3)
        #expect(error?.next == "brew install swiftformat, or set format.path in .xcdev.local.yml")
        #expect(try project.read("Sources/App/C.swift") == "struct C {\n\tlet c = 1\n}")
        #expect(formatters.runs.isEmpty)
    }

    @Test func pathsNarrowTheScopeAndAreReadFromTheCurrentDirectory() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        try project.change()
        let ctx = try await project.context()
        let one = try await project.service(formatters, from: project.root + "/Sources").format(FormatOptions(paths: ["App/C.swift"]), in: ctx)
        #expect(one.files == 1 && one.changed.map(\.file) == ["Sources/App/C.swift"])
        #expect(try project.read("Sources/App/A.swift").contains("let d = 40  \n"))                 // not in scope, so not formatted
        let none = try await project.service(formatters).format(FormatOptions(paths: ["Docs"]), in: ctx)
        #expect(none.failure == nil && none.files == 0)
        #expect(none.text == "format: no Swift files changed since main under Docs  tool=swiftformat\nnote: `xcd format --all` formats the whole project")
    }

    @Test func twoScopesAreAUsageErrorThatSaysWhatNeitherDoes() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        let ctx = try await project.context()
        let both = await #expect(throws: XcdError.self) { _ = try await project.service(formatters).format(FormatOptions(files: true, all: true), in: ctx) }
        #expect(both?.code == .usage && both?.next == "pass one of them, or neither to reformat only the lines the change touched")
    }

    /// A file with an unresolved conflict counts as changed, and no formatter can read it. It is left as it was,
    /// listed with the formatter's own error, and the other files are still formatted.
    @Test func aFileTheFormatterCannotProcessIsListedAndTheOthersAreStillFormatted() async throws {
        for config in [FormatProject.swiftFormat, FormatProject.appleSwiftFormat] {
            let project = try FormatProject(config)
            defer { project.project.remove() }
            try project.change()
            let conflicted = "struct D {\n<<<<<<< HEAD\n    let d = 1  \n=======\n    let d = 2\n>>>>>>> main\n}\n"
            try project.project.write(conflicted, to: "Sources/App/D.swift")
            let ctx = try await project.context()
            let formatters = FakeFormatters()
            let report = try await project.service(formatters).format(FormatOptions(), in: ctx)

            #expect(try project.read("Sources/App/D.swift") == conflicted)
            #expect(try project.read("Sources/App/A.swift") == Self.lineSeven)
            #expect(report.changed.map(\.file) == ["Sources/App/A.swift", "Sources/App/C.swift"])
            #expect(report.failed.map(\.file) == ["Sources/App/D.swift"])
            #expect(report.failed.first?.message == (report.tool == "swift-format"
                ? "Sources/App/D.swift:2:1: error: source control conflict marker in source file"
                : "Sources/App/D.swift: error: Found conflict marker <<<<<<< at 2:1."))
            #expect(report.failure?.code == .formatFailed && report.failure?.message == "1 file could not be formatted")
            #expect(report.text.hasPrefix("format: 2 files reformatted, 1 could not be formatted  tool=\(report.tool)  files=3  base=main  0.0s\nlog: "))
        }
    }

    /// swift-format exits 0 and prints nothing for a file its `.swift-format-ignore` names. Written back, that
    /// would empty the file.
    @Test func aFileTheFormattersOwnIgnoreFileNamesIsLeftAsItIs() async throws {
        let project = try FormatProject(FormatProject.appleSwiftFormat)
        defer { project.project.remove() }
        try project.change()
        try project.project.write("Sources/App/C.swift\n", to: ".swift-format-ignore")
        let ctx = try await project.context()
        let report = try await project.service(formatters).format(FormatOptions(files: true), in: ctx)
        #expect(try project.read("Sources/App/C.swift") == "struct C {\n\tlet c = 1\n}")
        #expect(report.changed.map(\.file) == ["Sources/App/A.swift"] && report.failed.isEmpty && report.failure == nil)
        #expect(formatters.runs.count == 2)                                          // it was asked, and said nothing
    }

    @Test func theProjectsArgumentsAndPathReachTheFormatter() async throws {
        let config = FormatProject.swiftFormat + "  args: [\"--config\", \"ci/.swiftformat\"]\n  path: tools/swiftformat\n"
        let project = try FormatProject(config)
        defer { project.project.remove() }
        try project.change()
        try project.project.write("#!/bin/sh\n", to: "tools/swiftformat")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.root + "/tools/swiftformat")
        let ctx = try await project.context()
        _ = try await project.service(formatters, path: "/nowhere").format(FormatOptions(paths: ["Sources/App/A.swift"]), in: ctx)
        let call = try #require(project.fake.calls.first { $0.argv.first == "swiftformat" })
        #expect(call.executable == project.root + "/tools/swiftformat")
        #expect(call.arguments == ["stdin", "--stdin-path", project.root + "/Sources/App/A.swift", "--line-range", "7,7",
                                   "--cache", "ignore", "--quiet", "--config", "ci/.swiftformat"])
        #expect(call.workingDirectory == project.root)
    }

    /// Each file is a process of its own, and several run side by side, never more than the limit. The stand-in's
    /// first runs wait until three are under way: with one at a time they would wait in vain.
    @Test func formattersRunSideBySideUpToTheLimit() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        for number in 1...12 { try project.project.write("let n = \(number)   \n", to: "Sources/App/N\(number).swift") }
        let ctx = try await project.context()
        let formatters = FakeFormatters(together: 3)
        var service = project.service(formatters)
        service.atOnce = 3
        let report = try await service.format(FormatOptions(), in: ctx)
        #expect(report.changed.count == 12 && formatters.runs.count == 12)
        #expect(formatters.mostAtOnce == 3)
        #expect(report.changed.map(\.file) == report.changed.map(\.file).sorted())    // in the files' order, whichever finished first
        #expect(FormatService.mostAtOnce == 8 && project.service(formatters).atOnce == 8)
    }

    @Test func aFileTheChangeOnlyRenamedIsNotFormatted() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        try project.project.git("mv", "Sources/App/A.swift", "Sources/App/Renamed.swift")
        let ctx = try await project.context()
        let report = try await project.service(formatters).format(FormatOptions(), in: ctx)
        #expect(report.files == 1 && report.changed.isEmpty && formatters.runs.isEmpty)
        #expect(report.text == "format: nothing to reformat  tool=swiftformat  files=1  base=main  0.0s")
        #expect(try project.read("Sources/App/Renamed.swift") == FormatProject.base)
        // Renamed and edited: the edited line is measured against the old path.
        try project.project.write(FormatProject.base.replacingOccurrences(of: "    let b = 2\n", with: "    let b = 20  \n"), to: "Sources/App/Renamed.swift")
        let edited = try await project.service(formatters).format(FormatOptions(), in: ctx)
        #expect(edited.changed == [FormatReport.Changed(file: "Sources/App/Renamed.swift", lines: [LineRange(3, 3)])])
    }

    /// SwiftFormat reads the text from a copy outside the worktree. No copy and no folder is left when the command ends.
    @Test func theCopiesForStandardInputAreOutsideTheWorktreeAndGoneAfterwards() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        try project.change()
        let ctx = try await project.context()
        _ = try await project.service(formatters).format(FormatOptions(), in: ctx)
        let inputs = formatters.runs.compactMap(\.inputFile)
        #expect(inputs.count == 2 && inputs.allSatisfy { !Paths.canonical($0).hasPrefix(project.root + "/") })
        let folders = Set(inputs.map { ($0 as NSString).deletingLastPathComponent })
        #expect(folders.count == 1 && folders.allSatisfy { ($0 as NSString).lastPathComponent.hasPrefix("xcd-format-") })
        #expect(folders.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    @Test func whatTheFormatterWarnsOfIsANoteSaidOnce() async throws {
        let project = try FormatProject(FormatProject.appleSwiftFormat)
        defer { project.project.remove() }
        try project.change()
        let ctx = try await project.context()
        let noisy = FakeFormatters(stderr: "<unknown>: warning: Configuration contains an unrecognized rule: NoSuchRule\n")
        let report = try await project.service(noisy).format(FormatOptions(), in: ctx)
        #expect(report.notes == ["swift-format: <unknown>: warning: Configuration contains an unrecognized rule: NoSuchRule"])
        #expect(report.failure == nil && report.text.contains("\nlog: "))
    }

    /// Given lines of such a file, both formatters damage the lines around them. It is listed, and `--files` formats it.
    @Test func aChangedFileWithWindowsLineEndingsIsFormattedWholeOrNotAtAll() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        let windows = FormatProject.base.replacingOccurrences(of: "\n", with: "\r\n")
        try project.project.write(windows, to: "Sources/App/W.swift")
        try project.project.commit("A file with Windows line endings")
        try project.project.git("branch", "-f", "main", "HEAD")
        try project.project.write(windows.replacingOccurrences(of: "let d = 4\r\n", with: "let d = 40  \r\n"), to: "Sources/App/W.swift")
        let ctx = try await project.context()
        let byLines = try await project.service(formatters).format(FormatOptions(), in: ctx)
        #expect(byLines.failure?.code == .formatFailed && byLines.failed.map(\.file) == ["Sources/App/W.swift"])
        #expect(byLines.failed.first?.message.hasPrefix("Sources/App/W.swift: has Windows line endings (CRLF)") == true)
        #expect(formatters.runs.isEmpty)
        let whole = try await project.service(formatters).format(FormatOptions(files: true), in: ctx)
        #expect(whole.failure == nil && whole.changed.map(\.file) == ["Sources/App/W.swift"])
    }
}
