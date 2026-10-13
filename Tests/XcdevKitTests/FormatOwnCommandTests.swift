import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd format` with a project's own command. Git and /bin/sh are real, and the commands are
/// small shell scripts: `strip` takes the blanks off the end of every line of the files it is given, and `check`
/// names the files that have such blanks and exits 1 when there are any.
@Suite struct FormatOwnCommandTests {
    static let strip = #"for f in "$@"; do sed -i '' -e 's/[[:space:]]*$//' "$f"; done"#
    static let check = #"bad=0; for f in "$@"; do if grep -q '[[:space:]]$' "$f"; then echo "$f needs formatting"; bad=1; fi; done; exit $bad"#

    static func config(run: String, check: String? = nil) -> String {
        "version: 1\nproject: App.xcodeproj\nformat:\n  run: |\n    \(run)\n" + (check.map { "  check: |\n    \($0)\n" } ?? "")
    }

    let formatters = FakeFormatters()

    @Test func theCommandRewritesFilesAndXcdListsTheOnesThatDiffer() async throws {
        let project = try FormatProject(Self.config(run: Self.strip))
        defer { project.project.remove() }
        try project.change()
        let ctx = try await project.context()
        let report = try await project.service(formatters).format(FormatOptions(), in: ctx)

        #expect(report.tool == Self.strip && report.scope == .files)                 // a command sees whole files
        #expect(report.base == "main" && report.baseCommit == project.fork && report.files == 2)
        #expect(try project.read("Sources/App/A.swift") == "struct A {\n    let a = 1\n    let b = 2\n    func f() {\n\t\tlet c = 3\n    }\n    let d = 40\n}\n")
        #expect(report.changed == [FormatReport.Changed(file: "Sources/App/A.swift", lines: nil)])   // C had no such blanks
        #expect(report.exitCode == 0 && report.failure == nil && report.notes.isEmpty)
        #expect(report.text == "format: 1 file reformatted  tool=\(Self.strip)  files=2  base=main  0.0s\nSources/App/A.swift")
        #expect(report.log?.hasSuffix("-format.log") == true)
        #expect(formatters.runs.isEmpty)
        let again = try await project.service(formatters).format(FormatOptions(), in: ctx)
        #expect(again.changed.isEmpty && again.text.hasPrefix("format: nothing to reformat  tool="))
    }

    @Test func aCheckRunsTheCheckCommandAndRewritesNothing() async throws {
        let project = try FormatProject(Self.config(run: Self.strip, check: Self.check))
        defer { project.project.remove() }
        try project.change()
        let changed = try project.read("Sources/App/A.swift")
        let ctx = try await project.context()
        let report = try await project.service(formatters).format(FormatOptions(check: true), in: ctx)

        #expect(try project.read("Sources/App/A.swift") == changed)
        #expect(report.check && report.exitCode == 1 && report.changed.isEmpty)
        #expect(report.failure?.code == .formatFailed && report.failure?.message == "the project's check command exited 1")
        #expect(Renderer.report(report, command: "format", format: .text) == """
        format: failed  tool=bad=0; for f in "$@"; do if grep -q '[[:space:]]$' "$f"; then echo "$f needs formatting"; bad=1; fi; done; exit $bad  files=2  base=main  0.0s
        Sources/App/A.swift needs formatting
        next: run `xcd format` to reformat, then `xcd format --check` again
        """)
        _ = try await project.service(formatters).format(FormatOptions(), in: ctx)
        let passed = try await project.service(formatters).format(FormatOptions(check: true), in: ctx)
        #expect(passed.failure == nil && passed.exitCode == 0 && passed.text.hasPrefix("format: passed  tool=bad=0;"))
    }

    /// `run` rewrites files, so it is never what a check falls back to.
    @Test func aCheckWithoutACheckCommandIsNotConfiguredAndRunsNothing() async throws {
        let project = try FormatProject(Self.config(run: "touch ran; " + Self.strip))
        defer { project.project.remove() }
        try project.change()
        let ctx = try await project.context()
        let error = await #expect(throws: XcdError.self) { _ = try await project.service(formatters).format(FormatOptions(check: true), in: ctx) }
        #expect(error?.code == .notConfigured && error?.code.exitCode == 2)
        #expect(error?.message == "this project's format command has no check: format.check is not set")
        #expect(error?.next == "add `check:` beside `run:` under `format:` in .xcdev.yml: a command that reports what `run` would change and rewrites nothing")
        #expect(!FileManager.default.fileExists(atPath: project.root + "/ran"))
        #expect(try project.read("Sources/App/A.swift").contains("let d = 40  \n"))
    }

    /// With `--all` and no paths the command is handed no files and covers the project its own way. xcd still reads
    /// every Swift file git knows before and after.
    @Test func allHandsOverNoFilesAndStillTellsWhatWasRewritten() async throws {
        let run = #"echo "$# files"; printf 'func b() { }\n' > Sources/App/B.swift"#
        let project = try FormatProject(Self.config(run: run))
        defer { project.project.remove() }
        try project.change()
        let ctx = try await project.context()
        let report = try await project.service(formatters).format(FormatOptions(all: true), in: ctx)
        #expect(report.scope == .all && report.base == nil && report.files == 3)
        #expect(report.output == "0 files\n" && report.notes.isEmpty)                // none in scope to hand over, so no note
        #expect(report.changed == [FormatReport.Changed(file: "Sources/App/B.swift", lines: nil)])
        let narrowed = try await project.service(formatters).format(FormatOptions(paths: ["Sources"], all: true), in: ctx)
        #expect(narrowed.output == "3 files\n")
    }

    @Test func aCommandThatNamesNoFilesGetsANoteThatNamesItsSetting() async throws {
        let project = try FormatProject(Self.config(run: "true", check: "true"))
        defer { project.project.remove() }
        try project.change()
        let ctx = try await project.context()
        let ran = try await project.service(formatters).format(FormatOptions(), in: ctx)
        #expect(ran.notes == [#"format.run has no "$@", so the command did not get the 2 files in scope; write "$@" where the files go"#])
        let checked = try await project.service(formatters).format(FormatOptions(check: true), in: ctx)
        #expect(checked.notes == [#"format.check has no "$@", so the command did not get the 2 files in scope; write "$@" where the files go"#])
        #expect(checked.failure == nil && checked.text.hasPrefix("format: passed  tool=true  files=2  base=main  0.0s\nnote: format.check has no"))
    }

    @Test func aCommandThatFailsIsFormatFailedAndWhatItRewroteIsStillListed() async throws {
        let project = try FormatProject(Self.config(run: Self.strip + "; echo broke >&2; exit 3"))
        defer { project.project.remove() }
        try project.change()
        let ctx = try await project.context()
        let report = try await project.service(formatters).format(FormatOptions(), in: ctx)
        #expect(report.exitCode == 3 && report.failure?.code == .formatFailed && report.failure?.message == "the project's format command exited 3")
        #expect(report.changed.map(\.file) == ["Sources/App/A.swift"] && report.output == "broke\n")
        #expect(report.text.hasPrefix("format: failed  tool="))
        #expect(report.text.hasSuffix("\nbroke\nSources/App/A.swift"))
    }

    @Test func withNothingInScopeTheCommandIsNotRun() async throws {
        let project = try FormatProject(Self.config(run: "touch ran"))
        defer { project.project.remove() }
        let ctx = try await project.context()
        let report = try await project.service(formatters).format(FormatOptions(), in: ctx)
        #expect(report.text == "format: no Swift files changed since main  tool=touch ran\nnote: `xcd format --all` formats the whole project")
        #expect(!FileManager.default.fileExists(atPath: project.root + "/ran") && report.exitCode == nil)
    }
}
