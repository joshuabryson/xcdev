import Foundation
import Testing
@testable import XcdevKit

/// What `xcd format` prints, and what it fails with.
@Suite struct FormatReportTests {
    static let base = ResolvedBase(name: "main", forkPoint: "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567")
    static let login = FormatReport.Changed(file: "Sources/App/LoginView.swift", lines: [LineRange(40, 47)])
    static let session = FormatReport.Changed(file: "Sources/App/Session.swift", lines: [LineRange(88, 91), LineRange(120, 120)])
    static let broken = FormatReport.Failed(file: "Sources/App/Broken.swift", message: "Sources/App/Broken.swift:2:10: error: expected ')' to end parameter clause")

    /// A SwiftFormat result over three files against `main`.
    func report(_ scope: QualityScope = .lines, check: Bool = false, changed: [FormatReport.Changed] = [], failed: [FormatReport.Failed] = []) -> FormatReport {
        var report = FormatReport(tool: "swiftformat", scope: scope, base: scope == .all ? nil : Self.base, files: 3, check: check, worktree: "feat")
        report.changed = changed
        report.failed = failed
        report.seconds = 0.62
        report.log = "/w/.xcdev/logs/20261012-181500-format.log"
        return report
    }

    func text(_ report: FormatReport) -> String { Renderer.report(report, command: "format", format: .text) }

    @Test func reformattedFilesAreListedWithTheirLines() {
        let report = report(changed: [Self.login, Self.session])
        #expect(report.failure == nil)
        #expect(text(report) == """
        format: 2 files reformatted  tool=swiftformat  files=3  base=main  0.6s
        Sources/App/LoginView.swift  lines 40-47
        Sources/App/Session.swift  lines 88-91, 120
        """)
        let one = FormatReport.Changed(file: "A.swift", lines: [LineRange(12, 12)])
        #expect(text(self.report(.all, changed: [one])) == "format: 1 file reformatted  tool=swiftformat  files=3  0.6s\nA.swift  line 12")
    }

    @Test func nothingToDoSaysSo() {
        #expect(text(report()) == "format: nothing to reformat  tool=swiftformat  files=3  base=main  0.6s")
        #expect(text(report(.files, check: true)) == "format: nothing to reformat  tool=swiftformat  files=3  base=main  0.6s")
        #expect(report(check: true).failure == nil)
    }

    @Test func aCheckThatFoundSomethingFailsAndNamesTheCommandThatFixesIt() {
        let report = report(check: true, changed: [Self.login, Self.session])
        #expect(report.failure?.code == .formatFailed && report.failure?.message == "2 files need formatting")
        #expect(text(report) == """
        format: 2 files need formatting  tool=swiftformat  files=3  base=main  0.6s
        Sources/App/LoginView.swift  lines 40-47
        Sources/App/Session.swift  lines 88-91, 120
        next: run `xcd format` to reformat them
        """)
        let one = self.report(check: true, changed: [Self.login])
        #expect(text(one).hasPrefix("format: 1 file needs formatting  ") && one.failure?.next == "run `xcd format` to reformat it")
    }

    /// A file the formatter could not process is listed with the formatter's own lines, after the files it did format.
    @Test func aFileThatCouldNotBeFormattedFailsTheCommandAndTheOthersAreStillListed() {
        let report = report(changed: [Self.login], failed: [Self.broken])
        #expect(report.failure?.code == .formatFailed && report.failure?.message == "1 file could not be formatted")
        #expect(text(report) == """
        format: 1 file reformatted, 1 could not be formatted  tool=swiftformat  files=3  base=main  0.6s
        log: /w/.xcdev/logs/20261012-181500-format.log
        Sources/App/LoginView.swift  lines 40-47
        Sources/App/Broken.swift:2:10: error: expected ')' to end parameter clause
        next: each file's line says why; put that right, then run `xcd format` again
        """)
        let only = self.report(check: true, failed: [Self.broken, Self.broken])
        #expect(text(only).hasPrefix("format: 2 files could not be formatted  tool=swiftformat"))
        #expect(only.failure?.next == "each file's line says why; put that right, then run `xcd format` again")
    }

    @Test func notesComeAfterTheFirstLineWithTheLog() {
        var report = report(changed: [Self.login])
        report.notes = LintReport.toolNotes(["warning: a", "warning: b", "warning: c", "warning: d"], from: "swiftformat")
        #expect(text(report) == """
        format: 1 file reformatted  tool=swiftformat  files=3  base=main  0.6s
        note: swiftformat: warning: a
        note: swiftformat: warning: b
        note: swiftformat: warning: c
        note: swiftformat: 1 more line is in the log
        log: /w/.xcdev/logs/20261012-181500-format.log
        Sources/App/LoginView.swift  lines 40-47
        """)
    }

    @Test func nothingInScopeSaysSoAndPointsAtTheWholeProject() {
        func empty(_ scope: QualityScope, base: ResolvedBase?) -> FormatReport {
            FormatReport(tool: "swift-format", scope: scope, base: base, files: 0, check: false, worktree: "feat")
        }
        let none = empty(.lines, base: Self.base).nothingInScope(under: [])
        #expect(none.failure == nil)
        #expect(none.text == "format: no Swift files changed since main  tool=swift-format\nnote: `xcd format --all` formats the whole project")
        #expect(empty(.files, base: Self.base).nothingInScope(under: ["Docs", ""]).text.hasPrefix("format: no Swift files changed since main under Docs, .  tool=swift-format\n"))
        #expect(empty(.all, base: nil).nothingInScope(under: []).text == "format: no Swift files in the project  tool=swift-format")
        #expect(empty(.all, base: nil).nothingInScope(under: ["Docs"]).text == "format: no Swift files under Docs  tool=swift-format")
    }

    @Test func aProjectWithNoFormatterSaysSoAndPointsAtAConfigFile() {
        let off = FormatReport.off(scope: .lines, configured: [], check: true, worktree: "feat")
        #expect(off.failure == nil && off.check && off.text == "format: no formatter is set up  (format.tool is none)")
        #expect(FormatReport.off(scope: .lines, configured: [.swiftFormat], check: false, worktree: "feat").text == """
        format: no formatter is set up  (format.tool is none)
        note: .swiftformat found: set `format.tool: swiftformat` in .xcdev.yml to have `xcd format` use it
        """)
        #expect(FormatReport.off(scope: .all, configured: [.appleSwiftFormat, .swiftFormat], check: false, worktree: "feat").notes
                == [".swift-format and .swiftformat found: set `format.tool` in .xcdev.yml to the formatter the project uses to have `xcd format` run it"])
    }

    /// A project's own command: xcd knows which files changed, not which lines, and shows what the command printed.
    @Test func aProjectsOwnCommandIsNamedAndItsOutputShown() {
        var ran = FormatReport(tool: #"./scripts/format.sh "$@""#, scope: .files, base: Self.base, files: 3, check: false, worktree: "feat")
        ran.exitCode = 0
        ran.output = "formatted 2 files\n"
        ran.changed = [FormatReport.Changed(file: "Sources/App/LoginView.swift", lines: nil)]
        ran.seconds = 2.1
        #expect(ran.failure == nil)
        #expect(text(ran) == """
        format: 1 file reformatted  tool=./scripts/format.sh "$@"  files=3  base=main  2.1s
        formatted 2 files
        Sources/App/LoginView.swift
        """)
        ran.exitCode = 3
        #expect(ran.failure?.code == .formatFailed && ran.failure?.message == "the project's format command exited 3")
        #expect(text(ran).hasPrefix("format: failed  tool=./scripts/format.sh"))
        #expect(text(ran).hasSuffix("\nnext: fix what it reports and run `xcd format` again"))
    }

    @Test func aProjectsOwnCheckPassesOrFails() {
        var checked = FormatReport(tool: #"./scripts/format.sh --dry "$@""#, scope: .files, base: Self.base, files: 3, check: true, worktree: "feat")
        checked.exitCode = 0
        #expect(checked.failure == nil && text(checked).hasPrefix("format: passed  tool=./scripts/format.sh --dry"))
        checked.exitCode = 1
        checked.output = "Sources/App/LoginView.swift needs formatting\n"
        #expect(checked.failure?.message == "the project's check command exited 1")
        #expect(text(checked) == """
        format: failed  tool=./scripts/format.sh --dry "$@"  files=3  base=main  0.0s
        Sources/App/LoginView.swift needs formatting
        next: run `xcd format` to reformat, then `xcd format --check` again
        """)
    }

    @Test func theJSONCarriesEachFileWithItsLinesAsPairs() throws {
        var report = report(check: true, changed: [Self.session, FormatReport.Changed(file: "B.swift", lines: nil)], failed: [Self.broken])
        report.notes = ["a note"]
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(Set(object.keys) == ["tool", "scope", "base", "baseCommit", "files", "check", "changed", "failed", "notes", "log", "seconds", "worktree"])
        #expect(object["scope"] as? String == "lines" && object["check"] as? Bool == true && object["baseCommit"] as? String == Self.base.forkPoint)
        let changed = try #require(object["changed"] as? [[String: Any]])
        #expect(changed[0]["file"] as? String == "Sources/App/Session.swift" && changed[0]["lines"] as? [[Int]] == [[88, 91], [120, 120]])
        #expect(changed[1].keys.sorted() == ["file"])
        #expect((object["failed"] as? [[String: String]])?.first == ["file": "Sources/App/Broken.swift", "message": Self.broken.message])
        let all = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(self.report(.all))) as? [String: Any])
        #expect(all["base"] == nil && all["baseCommit"] == nil && all["output"] == nil && all["exitCode"] == nil)
    }
}
