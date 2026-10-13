import Foundation
import Testing
@testable import XcdevKit

/// What `xcd lint` prints, and what it fails with.
@Suite struct LintReportTests {
    static let lineLength = LintFinding(file: "Sources/App/LoginView.swift", line: 42, column: 121, severity: .warning, rule: "line_length",
                                        message: "Line should be 120 characters or less; currently it has 134 characters")
    static let bodyLength = LintFinding(file: "Sources/App/Session.swift", line: 88, column: 1, severity: .error, rule: "function_body_length",
                                        message: "Function body should span 60 lines or less; currently spans 64 lines")

    /// A SwiftLint result over three files against `main`.
    func report(_ scope: QualityScope = .lines, findings: [LintFinding] = [], older: Int = 0, notes: [String] = []) -> LintReport {
        var report = LintReport(tool: "swiftlint", scope: scope, base: scope == .all ? nil : "main",
                                baseCommit: scope == .all ? nil : "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567", files: 3, worktree: "feat")
        report.findings = findings
        report.older = older
        report.notes = notes
        report.seconds = 1.84
        report.log = "/w/.xcdev/logs/20261011-181500-lint.log"
        return report
    }

    @Test func newFindingsAreListedAndOlderOnesCounted() {
        let report = report(findings: [Self.lineLength, Self.bodyLength], older: 14)
        #expect(Renderer.report(report, command: "lint", format: .text) == """
        lint: 2 new findings  tool=swiftlint  files=3  base=main  1.8s
        Sources/App/LoginView.swift:42:121: warning: Line should be 120 characters or less; currently it has 134 characters (line_length)
        Sources/App/Session.swift:88:1: error: Function body should span 60 lines or less; currently spans 64 lines (function_body_length)
        14 older findings in these files (xcd lint --files)
        next: fix the findings and run `xcd lint` again
        """)
        #expect(report.failure?.code == .lintFailed)
        #expect(report.failure?.message == "1 of the 2 findings is an error")
    }

    @Test func warningsAreListedAndTheCommandSucceeds() {
        let report = report(findings: [Self.lineLength], older: 1)
        #expect(report.failure == nil)
        #expect(report.text == """
        lint: 1 new finding  tool=swiftlint  files=3  base=main  1.8s
        Sources/App/LoginView.swift:42:121: warning: Line should be 120 characters or less; currently it has 134 characters (line_length)
        1 older finding in these files (xcd lint --files)
        """)
    }

    @Test func theFirstLineSaysWhatIsShownInEachScope() {
        #expect(report().text == "lint: no new findings  tool=swiftlint  files=3  base=main  1.8s")
        #expect(report(older: 5).text.hasPrefix("lint: no new findings  tool=swiftlint  files=3  base=main  1.8s\n5 older findings"))
        #expect(report(.files).text == "lint: no findings  tool=swiftlint  files=3  base=main  1.8s")
        #expect(report(.files, findings: [Self.lineLength]).text.hasPrefix("lint: 1 finding  tool=swiftlint  files=3  base=main  1.8s\n"))
        #expect(report(.all, findings: [Self.lineLength, Self.bodyLength]).text.hasPrefix("lint: 2 findings  tool=swiftlint  files=3  1.8s\n"))
    }

    /// What the tool wrote to stderr comes before the findings: three lines at most, then where the rest is.
    @Test func theToolsOwnWarningsComeFirstWithTheLog() {
        let few = report(findings: [Self.lineLength], notes: ["swiftlint: warning: Cannot parse YAML file – Falling back to default configuration"])
        #expect(few.text == """
        lint: 1 new finding  tool=swiftlint  files=3  base=main  1.8s
        note: swiftlint: warning: Cannot parse YAML file – Falling back to default configuration
        log: /w/.xcdev/logs/20261011-181500-lint.log
        Sources/App/LoginView.swift:42:121: warning: Line should be 120 characters or less; currently it has 134 characters (line_length)
        """)
        #expect(LintReport.toolNotes(["a", "b", "c"], from: "swiftlint") == ["swiftlint: a", "swiftlint: b", "swiftlint: c"])
        #expect(LintReport.toolNotes((1...269).map { "line \($0)" }, from: "swiftlint")
                == ["swiftlint: line 1", "swiftlint: line 2", "swiftlint: line 3", "swiftlint: 266 more lines are in the log"])
        #expect(LintReport.toolNotes(["a", "b", "c", "d"], from: "swiftlint").last == "swiftlint: 1 more line is in the log")
        #expect(report().text == "lint: no new findings  tool=swiftlint  files=3  base=main  1.8s")       // no notes, no log line
    }

    @Test func nothingInScopeSaysSoAndPointsAtTheWholeProject() {
        func empty(_ tool: String, _ scope: QualityScope, base: String?) -> LintReport {
            LintReport(tool: tool, scope: scope, base: base, baseCommit: nil, files: 0, worktree: "feat")
        }
        let none = empty("swiftlint", .lines, base: "main").nothingInScope(under: [])
        #expect(none.failure == nil)
        #expect(none.text == """
        lint: no Swift files changed since main  tool=swiftlint
        note: `xcd lint --all` lints the whole project
        """)
        let narrowed = empty("swiftlint", .files, base: "develop").nothingInScope(under: ["Sources/App", "Tests"])
        #expect(narrowed.text.hasPrefix("lint: no Swift files changed since develop under Sources/App, Tests  tool=swiftlint\n"))
        let all = empty("./scripts/lint.sh", .all, base: nil).nothingInScope(under: [])
        #expect(all.text == "lint: no Swift files in the project  tool=./scripts/lint.sh")
        let allNarrowed = empty("swiftlint", .all, base: nil).nothingInScope(under: ["Docs"])
        #expect(allNarrowed.text == "lint: no Swift files under Docs  tool=swiftlint")
    }

    @Test func aProjectWithNoLinterSaysSoAndSucceeds() {
        let off = LintReport.off(scope: .lines, hasConfigFile: false, worktree: "feat")
        #expect(off.failure == nil)
        #expect(off.text == "lint: no linter is set up  (lint.tool is none)")
        #expect(LintReport.off(scope: .lines, hasConfigFile: true, worktree: "feat").text == """
        lint: no linter is set up  (lint.tool is none)
        note: .swiftlint.yml found: set `lint.tool: swiftlint` in .xcdev.yml to have `xcd lint` use it
        """)
    }

    @Test func aProjectsOwnCommandPassesOrFailsWithItsOutput() {
        var passed = LintReport(tool: "./scripts/lint.sh", scope: .files, base: "main", baseCommit: "0a1b2c3", files: 3, worktree: "feat")
        passed.exitCode = 0
        passed.output = "checked 3 files\n"
        passed.seconds = 2.1
        #expect(passed.failure == nil)
        #expect(passed.text == "lint: passed  tool=./scripts/lint.sh  files=3  base=main  2.1s\nchecked 3 files")

        var failed = passed
        failed.exitCode = 3
        failed.output = "Sources/A.swift:1: bad\n\n1 problem\n"
        #expect(Renderer.report(failed, command: "lint", format: .text) == """
        lint: failed  tool=./scripts/lint.sh  files=3  base=main  2.1s
        Sources/A.swift:1: bad

        1 problem
        next: fix what it reports and run `xcd lint` again
        """)
        #expect(failed.failure?.code == .lintFailed && failed.failure?.message == "the project's lint command exited 3")
    }

    /// A failing result is still the whole result: `data` beside `error`.
    @Test func jsonCarriesTheFindingsBesideTheError() throws {
        let json = Renderer.report(report(findings: [Self.bodyLength], older: 2, notes: ["swiftlint: warning: x"]), command: "lint", format: .json)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == false && object["worktree"] as? String == "feat")
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "lint_failed" && error["next"] as? String == "fix the findings and run `xcd lint` again")
        let data = try #require(object["data"] as? [String: Any])
        #expect(data["tool"] as? String == "swiftlint" && data["scope"] as? String == "lines")
        #expect(data["base"] as? String == "main" && data["baseCommit"] as? String == "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567")
        #expect(data["files"] as? Int == 3 && data["older"] as? Int == 2 && data["seconds"] as? Double == 1.84)
        #expect(data["notes"] as? [String] == ["swiftlint: warning: x"] && data["log"] as? String == "/w/.xcdev/logs/20261011-181500-lint.log")
        let finding = try #require((data["findings"] as? [[String: Any]])?.first)
        #expect(finding["file"] as? String == "Sources/App/Session.swift" && finding["line"] as? Int == 88 && finding["column"] as? Int == 1)
        #expect(finding["severity"] as? String == "error" && finding["rule"] as? String == "function_body_length")
        #expect((finding["message"] as? String)?.hasPrefix("Function body should span") == true)

        let all = Renderer.report(report(.all), command: "lint", format: .json)
        #expect(all.contains(#""scope":"all""#) && !all.contains("\"base\"") && !all.contains("baseCommit") && all.contains(#""ok":true"#))
    }
}
