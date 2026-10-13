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
    func install(stderr: String = "", _ change: @escaping @Sendable (Int, String) -> [String]) {
        runner.stub(["swiftformat"]) { [inputs] invocation in
            let text = try String(contentsOfFile: invocation.inputFile ?? "", encoding: .utf8)
            inputs.change { $0.append(text) }
            var range = 1...Int.max
            if let flag = invocation.arguments.firstIndex(of: "--line-range") {
                let ends = invocation.arguments[flag + 1].split(separator: ",").compactMap { Int($0) }
                range = ends[0]...ends[1]
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().enumerated()
            let printed = lines.flatMap { range.contains($0.offset + 1) ? change($0.offset + 1, String($0.element)) : [String($0.element)] }
            return ProcessOutput(exitCode: 0, stdout: printed.map { $0 + "\n" }.joined(), stderr: stderr)
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
        #expect(answer.said == ["swiftformat changed a line above lines 6-7, the range it was given, so the file was left as it was"])
        #expect(runner.calls.count == 1)                                             // the pass for lines 2-2 never ran
        // A range that starts at line 1 has no line above it.
        #expect(try await tool(scratch).format(job([LineRange(1, 3)])).text == "// a header\n" + Self.ten)
    }

    /// The lines above are compared as bytes: Swift takes CRLF for one character, and two spellings of an accented
    /// letter for the same text.
    @Test func theLinesAboveARangeAreComparedByteForByte() {
        #expect(SwiftFormatTool.keepsLinesAbove(LineRange(3, 3), "a\nb\nc\n", "a\nb\nC\n"))
        #expect(SwiftFormatTool.keepsLinesAbove(LineRange(3, 3), "a\r\nb\r\nc\r\n", "a\r\nb\r\nC\r\n"))
        #expect(!SwiftFormatTool.keepsLinesAbove(LineRange(3, 3), "a\r\nb\r\nc\r\n", "a\r\nb\nC\r\n"))
        #expect(!SwiftFormatTool.keepsLinesAbove(LineRange(2, 2), "// caf\u{E9}\nb\n", "// cafe\u{301}\nB\n"))
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
