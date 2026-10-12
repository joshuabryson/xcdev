import Foundation
import Testing
@testable import XcdevKit

/// Which findings a change introduced. No process and no file: text and lists in, lists out.
@Suite struct FindingComparisonTests {
    /// A version of a file with findings on some of its lines, each written as (line, rule).
    func version(_ text: String, _ findings: [(line: Int, rule: String)]) -> FileFindings {
        FileFindings(text: text, findings: findings.map {
            LintFinding(file: "A.swift", line: $0.line, column: 1, severity: .warning, rule: $0.rule, message: "\($0.rule) at \($0.line)")
        })
    }

    /// The lines of the new findings, in line order.
    func newLines(_ current: FileFindings, against base: FileFindings?) -> [Int] {
        FindingComparison.newFindings(in: current, against: base).compactMap(\.line)
    }

    static let base = """
    import Foundation
    func first() {
        print("one")
    }
    func second() {
        print("two")
    }
    """

    @Test func findingsThatOnlyMovedDownAreOld() {
        let base = version(Self.base, [(3, "no_print"), (6, "no_print")])
        let current = version("// A new comment\n\n" + Self.base, [(5, "no_print"), (8, "no_print")])
        #expect(newLines(current, against: base).isEmpty)
    }

    /// Adding lines to a function makes the linter report the function's first line, which the change did not touch.
    @Test func aFindingOnAnUntouchedLineIsNewWhenTheBaseLacksIt() {
        let base = version(Self.base, [(3, "no_print")])
        let longer = Self.base.replacingOccurrences(of: "    print(\"two\")\n", with: "    print(\"two\")\n    work()\n    work()\n")
        let current = version(longer, [(3, "no_print"), (5, "function_body_length")])
        #expect(newLines(current, against: base) == [5])
    }

    @Test func aFindingOnALineWhoseTextChangedIsNew() {
        let base = version(Self.base, [(3, "no_print"), (6, "no_print")])
        let edited = Self.base.replacingOccurrences(of: "print(\"two\")", with: "print(\"two\", \"three\")")
        #expect(newLines(version(edited, [(3, "no_print"), (6, "no_print")]), against: base) == [6])
    }

    @Test func aLineThatWasOnlyIndentedAgainKeepsItsFindings() {
        let base = version(Self.base, [(3, "no_print")])
        let indented = Self.base.replacingOccurrences(of: "    print(\"one\")", with: "\t\tprint(\"one\")  ")
        #expect(newLines(version(indented, [(3, "no_print")]), against: base).isEmpty)
    }

    /// The message carries numbers that change ("currently spans 64 lines"), so it does not identify a finding.
    @Test func aFunctionThatWasTooLongAndGrewIsAnOldFinding() {
        let base = FileFindings(text: Self.base, findings: [
            LintFinding(file: "A.swift", line: 2, column: 1, severity: .warning, rule: "function_body_length", message: "currently spans 61 lines"),
        ])
        let current = FileFindings(text: Self.base, findings: [
            LintFinding(file: "A.swift", line: 2, column: 1, severity: .error, rule: "function_body_length", message: "currently spans 64 lines"),
        ])
        #expect(FindingComparison.newFindings(in: current, against: base).isEmpty)
    }

    @Test func oneMoreOfAnIdenticalFindingIsOneNewFinding() {
        let text = "print(x)\nwork()\nprint(x)\nwork()\nprint(x)\n"
        let base = version("print(x)\nwork()\nprint(x)\n", [(1, "no_print"), (3, "no_print")])
        let current = version(text, [(1, "no_print"), (3, "no_print"), (5, "no_print")])
        #expect(newLines(current, against: base).count == 1)
        #expect(newLines(base, against: current).isEmpty)                    // one fewer is no new finding
    }

    /// Two functions changed places. In line order their findings no longer follow each other as before, and a
    /// longest-common-sequence match alone would call one of them new.
    @Test func findingsInCodeThatChangedPlacesAreOld() {
        let base = version("func a() { print(1) }\nlet x = 1 // TODO: x\nfunc b() { print(2) }\n",
                           [(1, "no_print"), (2, "todo"), (3, "no_print")])
        let current = version("func b() { print(2) }\nlet x = 1 // TODO: x\nfunc a() { print(1) }\n",
                              [(1, "no_print"), (2, "todo"), (3, "no_print")])
        #expect(newLines(current, against: base).isEmpty)
    }

    @Test func aSecondRuleOnTheSameLineIsNew() {
        let base = version(Self.base, [(3, "no_print")])
        #expect(FindingComparison.newFindings(in: version(Self.base, [(3, "no_print"), (3, "line_length")]), against: base).map(\.rule)
                == ["line_length"])
    }

    @Test func everyFindingIsNewInAFileWithNoBaseVersion() {
        let current = version(Self.base, [(6, "no_print"), (3, "no_print")])
        #expect(newLines(current, against: nil) == [3, 6])
    }

    /// A rule about the whole file gives no line. It is matched by its rule alone.
    @Test func aFindingWithNoLineIsMatchedByItsRule() {
        let fileName = LintFinding(file: "A.swift", line: nil, column: nil, severity: .warning, rule: "file_name", message: "File name should match a type")
        let base = FileFindings(text: Self.base, findings: [fileName])
        let current = FileFindings(text: Self.base + "\nlet more = 1\n", findings: [fileName])
        #expect(FindingComparison.newFindings(in: current, against: base).isEmpty)
        #expect(FindingComparison.newFindings(in: current, against: version(Self.base, [])) == [fileName])
    }

    /// A line number past the end of the text (the file changed while it was linted) must not stop the command.
    @Test func aLineNumberPastTheEndOfTheFileIsNotACrash() {
        let current = version("one line\n", [(40, "no_print")])
        #expect(newLines(current, against: version("one line\n", [])) == [40])
    }

    @Test func windowsLineEndingsDoNotMakeEveryFindingNew() {
        let base = version("print(1)\nprint(2)\n", [(1, "no_print"), (2, "no_print")])
        let current = version("print(1)\r\nprint(2)\r\n", [(1, "no_print"), (2, "no_print")])
        #expect(newLines(current, against: base).isEmpty)
    }

    @Test func aFindingReadsAsACompilerDiagnosticWithItsRule() {
        let finding = LintFinding(file: "Sources/App/LoginView.swift", line: 42, column: 121, severity: .warning, rule: "line_length",
                                  message: "Line should be 120 characters or less; currently it has 134 characters")
        #expect(finding.text == "Sources/App/LoginView.swift:42:121: warning: Line should be 120 characters or less; currently it has 134 characters (line_length)")
        let whole = LintFinding(file: "A.swift", line: nil, column: nil, severity: .error, rule: "file_name", message: "Bad name")
        #expect(whole.text == "A.swift: error: Bad name (file_name)")
    }
}
