import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Running SwiftFormat on one file, range by range. The formatter is a stub that reads what it is
/// handed on standard input.
@Suite struct SwiftFormatToolTests {
    let runner = FakeProcessRunner()
    /// What each run was handed on standard input, in order.
    let inputs = Shared<[String]>([])

    static let ten = (1...10).map { "line \($0)\n" }.joined()

    func tool(_ scratch: ScratchFolder, args: [String] = []) -> SwiftFormatTool {
        SwiftFormatTool(runner: runner, executable: "/opt/homebrew/bin/swiftformat", args: args, worktreeRoot: "/work/My App", scratch: scratch)
    }

    func job(_ ranges: [LineRange]? = nil, text: String = SwiftFormatToolTests.ten) -> FormatJob {
        FormatJob(path: "Sources/App/A.swift", text: text, ranges: ranges)
    }

    /// A stand-in SwiftFormat: it reads its standard input and prints it with `change` applied to the lines of the
    /// range it was given (to every line without one). The lines are numbered from 1 and come without their newline.
    /// Like the real tool, it leaves a last line alone when no newline follows it.
    func install(stderr: String = "", _ change: @escaping @Sendable (Int, String) -> [String]) {
        runner.stub(["swiftformat"]) { [inputs] invocation in
            let text = try String(contentsOfFile: invocation.inputFile ?? "", encoding: .utf8)
            inputs.change { $0.append(text) }
            var range = 1...Int.max
            if let flag = invocation.arguments.firstIndex(of: "--line-range") {
                let ends = invocation.arguments[flag + 1].split(separator: ",").compactMap { Int($0) }
                range = ends[0]...ends[1]
            }
            let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
            let lines = parts.dropLast().enumerated()
            let printed = lines.flatMap { range.contains($0.offset + 1) ? change($0.offset + 1, String($0.element)) : [String($0.element)] }
            return ProcessOutput(exitCode: 0, stdout: printed.map { $0 + "\n" }.joined() + (parts.last ?? ""), stderr: stderr)
        }
    }

    @Test func aWholeFileGoesThroughOnceOnStandardInput() async throws {
        let scratch = try ScratchFolder.create(for: "format")
        defer { scratch.remove() }
        install { _, line in [line.uppercased()] }
        let answer = try await tool(scratch, args: ["--config", "ci/.swiftformat"]).format(job())
        #expect(answer.text == Self.ten.uppercased() && answer.said.isEmpty)
        let call = try #require(runner.calls.first)
        #expect(runner.calls.count == 1 && call.executable == "/opt/homebrew/bin/swiftformat")
        #expect(call.arguments == ["stdin", "--stdin-path", "/work/My App/Sources/App/A.swift", "--cache", "ignore", "--quiet", "--config", "ci/.swiftformat"])
        #expect(call.workingDirectory == "/work/My App" && call.timeout == .seconds(120))
        #expect(inputs.value == [Self.ten])                                          // the text as xcd read it
        #expect(call.inputFile?.hasPrefix(scratch.root + "/") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root).isEmpty)    // and the copy is gone afterwards
    }

    /// Each range is a run of its own, the last range first. Here the stand-in doubles every line of its range, so a
    /// pass makes the text longer: taken from the top, the second range would land on other lines.
    @Test func rangesGoThroughOneByOneTheLastFirstEachOnTheTextBefore() async throws {
        let scratch = try ScratchFolder.create(for: "format")
        defer { scratch.remove() }
        install { _, line in [line, line + " again"] }
        let answer = try await tool(scratch).format(job([LineRange(2, 2), LineRange(6, 7)]))

        #expect(runner.calls.map { $0.arguments.dropFirst(3).prefix(2).joined(separator: " ") } == ["--line-range 6,7", "--line-range 2,2"])
        #expect(answer.text == "line 1\nline 2\nline 2 again\nline 3\nline 4\nline 5\nline 6\nline 6 again\nline 7\nline 7 again\nline 8\nline 9\nline 10\n")
        #expect(inputs.value.count == 2 && inputs.value[0] == Self.ten)
        #expect(inputs.value[1] == "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 6 again\nline 7\nline 7 again\nline 8\nline 9\nline 10\n")
        #expect(answer.transcript.components(separatedBy: "$ swiftformat stdin").count == 3)
    }

    /// The earlier ranges are only right while a pass leaves the lines above its own range alone. One that does not
    /// is caught, and the file is left as it was.
    @Test func aPassThatChangesALineAboveItsRangeStopsTheFile() async throws {
        let scratch = try ScratchFolder.create(for: "format")
        defer { scratch.remove() }
        runner.stub(["swiftformat"]) { invocation in
            let text = try String(contentsOfFile: invocation.inputFile ?? "", encoding: .utf8)
            return ProcessOutput(exitCode: 0, stdout: "// a header\n" + text)                // a rule that puts a line on top
        }
        let answer = try await tool(scratch).format(job([LineRange(2, 2), LineRange(6, 7)]))
        #expect(answer.text == nil)
        #expect(answer.said == [Self.refusal("lines 6-7")])
        #expect(answer.transcript.hasSuffix(Self.refusal("lines 6-7") + "\n"))         // the log says why, after the pass's own lines
        #expect(runner.calls.count == 1)                                             // the pass for lines 2-2 never ran
        // A range that starts at line 1 has no line above it.
        #expect(try await tool(scratch).format(job([LineRange(1, 3)])).text == "// a header\n" + Self.ten)
        // One that starts at line 2 has line 1 above it, and a line put on top is not line 1 with more at its end.
        #expect(try await tool(scratch).format(job([LineRange(2, 3)])).said == [Self.refusal("lines 2-3")])
    }

    static func refusal(_ range: String) -> String {
        "swiftformat changed a line above \(range), the range it was given, so the file was left as it was; `xcd format --files` formats the file whole"
    }

    @Test func aRangeOfOneLineIsNamedAsOneLine() async throws {
        let scratch = try ScratchFolder.create(for: "format")
        defer { scratch.remove() }
        runner.stub(["swiftformat"]) { invocation in
            ProcessOutput(exitCode: 0, stdout: "// a header\n" + (try String(contentsOfFile: invocation.inputFile ?? "", encoding: .utf8)))
        }
        let answer = try await tool(scratch).format(job([LineRange(8, 8)]))
        #expect(answer.said == [Self.refusal("line 8")])
    }

    /// What the real tool does with ordinary code: `else {` alone on its line is joined to the `}` above it. That
    /// line keeps what it held and no line further up moves, so the pass is taken and the range above still names
    /// its line.
    @Test func anElseJoinedToTheBraceAboveIsTakenAndTheRangeAboveStillNamesItsLine() async throws {
        let scratch = try ScratchFolder.create(for: "format")
        defer { scratch.remove() }
        let given = "func f( ) {\n    if a {\n    }\n    else {\n    }\n}\n"
        let joined = "func f( ) {\n    if a {\n    } else {\n    }\n}\n"
        runner.stub(["swiftformat"]) { [inputs] invocation in
            let text = try String(contentsOfFile: invocation.inputFile ?? "", encoding: .utf8)
            inputs.change { $0.append(text) }
            let printed = invocation.arguments.contains("4,4") ? joined : text.replacingOccurrences(of: "f( )", with: "f()")
            return ProcessOutput(exitCode: 0, stdout: printed)
        }
        let answer = try await tool(scratch).format(job([LineRange(1, 1), LineRange(4, 4)], text: given))
        #expect(answer.text == "func f() {\n    if a {\n    } else {\n    }\n}\n" && answer.said.isEmpty)
        #expect(inputs.value == [given, joined])
        #expect(runner.calls.map { $0.arguments.dropFirst(3).prefix(2).joined(separator: " ") } == ["--line-range 4,4", "--line-range 1,1"])
    }

    /// What the real tool does with a line that starts with a comma, under a line that ends in a comment: the comma
    /// lands inside the comment, and the code no longer compiles. Such a pass is not
    /// taken, and no further pass runs.
    @Test func aCommaPutIntoTheCommentAboveRefusesTheFileAndTheLogSaysWhy() async throws {
        let scratch = try ScratchFolder.create(for: "format")
        defer { scratch.remove() }
        let given = "let v = f( \n    a: 1 // one\n    , b: 2\n)\n"
        runner.stub(["swiftformat"], stdout: "let v = f( \n    a: 1 // one, // one\n        b: 2\n)\n")
        let answer = try await tool(scratch).format(job([LineRange(1, 1), LineRange(3, 3)], text: given))
        #expect(answer.text == nil && answer.said == [Self.refusal("line 3")])
        #expect(runner.calls.count == 1 && answer.transcript.hasSuffix(Self.refusal("line 3") + "\n"))
    }

    /// The line directly above a range may come back with more at its end, as a join leaves it. Each pair is what the
    /// real tool was given and what it gave.
    @Test func theLineDirectlyAboveARangeMayGainTextAtItsEnd() {
        let keeps = SwiftFormatTool.keepsLinesAbove
        #expect(keeps(LineRange(3, 3), "if a {\n}\nelse {\n}\n", "if a {\n} else {\n}\n"))
        #expect(keeps(LineRange(4, 4), "let xs = [\n    1,\n    2\n]\n", "let xs = [\n    1,\n    2,\n]\n"))
        #expect(keeps(LineRange(3, 3), "f(\n    a: 1 /* one */\n    , b: 2\n)\n", "f(\n    a: 1 /* one */,\n    b: 2\n)\n"))
        #expect(keeps(LineRange(2, 3), "func f()\n{\n}\n", "func f() {}\n"))               // the line above is the first line
        #expect(keeps(LineRange(5, 5), "do {\n    g()\n}   \n\tcatch {\n}\n", "do {\n    g()\n}   \n\tcatch {\n}\n"))  // nothing joined
    }

    /// Any other change above a range still refuses the file. The blank line and the two comments are what the real
    /// tool gave: a `{` under a blank line takes the blank line's place, and a leading comma goes into the comment.
    @Test func aLineAboveARangeThatChangedAnyOtherWayIsNotKept() {
        let keeps = SwiftFormatTool.keepsLinesAbove
        #expect(!keeps(LineRange(4, 4), "let xs = [\n    1\n    // note\n    , 2\n]\n", "let xs = [\n    1,\n    // note\n    2\n]\n"))   // two lines up
        #expect(!keeps(LineRange(3, 3), "if a {\n    }\nelse {\n}\n", "if a {\n} else {\n}\n"))        // the line above lost its indentation
        #expect(!keeps(LineRange(3, 3), "if a {\n} // end\nelse {\n}\n", "if a {\n}\nelse {\n}\n"))        // and here its comment
        #expect(!keeps(LineRange(3, 4), "func f()\n\n{\n}\n", "func f()\n{\n}\n"))
        #expect(!keeps(LineRange(3, 4), "func f()\n  \t\n{\n}\n", "func f()\n  \t{\n}\n"))               // spaces and a tab are blank too
        #expect(!keeps(LineRange(4, 4), "f(\n    a: 1\n    // note\n    , b: 2\n)\n", "f(\n    a: 1\n    // note, // note\n        b: 2\n)\n"))
        #expect(!keeps(LineRange(3, 3), "f(\n    a: 1 // one\n    , b: 2\n)\n", "f(\n    a: 1 // one, // one\n        b: 2\n)\n"))
        // A blank line and a line with a comment are kept when they come back as they were.
        #expect(keeps(LineRange(3, 3), "func f()\n\ng( )\n", "func f()\n\ng()\n"))
        #expect(keeps(LineRange(3, 3), "f(\n    // note\n    b:2\n)\n", "f(\n    // note\n    b: 2\n)\n"))
    }

    /// The real tool leaves the last token of a text out of a range when no newline ends the text, and damages it.
    @Test func aRangedPassOverATextWithoutAFinalNewlineIsHandedOneAndTheNewlineIsTakenOffAgain() async throws {
        let scratch = try ScratchFolder.create(for: "format")
        defer { scratch.remove() }
        install { _, line in [line.uppercased()] }
        let answer = try await tool(scratch).format(job([LineRange(3, 3)], text: "line 1\nline 2\nline 3"))
        #expect(answer.text == "line 1\nline 2\nLINE 3")
        #expect(inputs.value == ["line 1\nline 2\nline 3\n"])
    }

    @Test func aTextThatEndsInANewlineIsHandedOverAsItIsAndSoIsOneFormattedWhole() async throws {
        let scratch = try ScratchFolder.create(for: "format")
        defer { scratch.remove() }
        install { _, line in [line.uppercased()] }
        let ranged = try await tool(scratch).format(job([LineRange(3, 3)], text: "a\nb\nc\n"))
        #expect(ranged.text == "a\nb\nC\n" && inputs.value == ["a\nb\nc\n"])
        let whole = try await tool(scratch).format(job(text: "a\nb\nc"))
        #expect(inputs.value.last == "a\nb\nc" && whole.text == "A\nB\nc")      // no range: as it is, and what the tool gave is kept
        let crlf = try await tool(scratch).format(job([LineRange(1, 1)], text: "a\r\n"))
        #expect(inputs.value.last == "a\r\n" && crlf.text == "a\r\n")                 // CRLF is one character to Swift, two bytes to the tool
        let empty = try await tool(scratch).format(job([LineRange(1, 1)], text: ""))
        #expect(inputs.value.last == "" && empty.text == "")
    }

    /// The lines above are compared as bytes: Swift takes CRLF for one character, and two spellings of an accented
    /// letter for the same text.
    @Test func theLinesAboveARangeAreComparedByteForByte() {
        #expect(SwiftFormatTool.keepsLinesAbove(LineRange(3, 3), "a\nb\nc\n", "a\nb\nC\n"))
        #expect(SwiftFormatTool.keepsLinesAbove(LineRange(3, 3), "a\r\nb\r\nc\r\n", "a\r\nb\r\nC\r\n"))
        #expect(!SwiftFormatTool.keepsLinesAbove(LineRange(3, 3), "a\r\nb\r\nc\r\n", "a\r\nb\nC\r\n"))
        #expect(!SwiftFormatTool.keepsLinesAbove(LineRange(3, 3), "let caf\u{E9} = 1\nb\nc\n", "let cafe\u{301} = 1\nb\nC\n"))
        #expect(!SwiftFormatTool.keepsLinesAbove(LineRange(3, 3), "a\nb\nc\n", "a\n"))
        #expect(SwiftFormatTool.keepsLinesAbove(LineRange(9, 9), "a\nb\n", "a\nb\n"))          // a range past the end
    }

    /// SwiftFormat exits 70 and prints its input back when it cannot format it. That text is not a result.
    @Test func aFailedPassGivesNoTextAndStopsTheFile() async throws {
        let scratch = try ScratchFolder.create(for: "format")
        defer { scratch.remove() }
        runner.stub(["swiftformat"], exitCode: 70, stdout: Self.ten, stderr: "error: Unexpected end of file at 4:1.\n")
        let answer = try await tool(scratch).format(job([LineRange(2, 2), LineRange(6, 7)]))
        #expect(answer.text == nil && answer.said == ["error: Unexpected end of file at 4:1."])
        #expect(runner.calls.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root).isEmpty)
    }

    @Test func noRangesAtAllRunsNothingAndWhatIsSaidTwiceIsKeptOnce() async throws {
        let scratch = try ScratchFolder.create(for: "format")
        defer { scratch.remove() }
        #expect(try await tool(scratch).format(job([])).text == Self.ten)
        #expect(runner.calls.isEmpty)
        install(stderr: "warning: no Swift version was given\n") { _, line in [line] }
        let answer = try await tool(scratch).format(job([LineRange(2, 2), LineRange(6, 7)]))
        #expect(runner.calls.count == 2 && answer.said == ["warning: no Swift version was given"])
    }
}
