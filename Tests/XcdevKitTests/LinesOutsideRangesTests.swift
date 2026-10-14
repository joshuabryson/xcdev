import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// A text that was handed to a formatter with ranges, and what the formatter gave for it.
struct RangeAnswer: Sendable, CustomTestStringConvertible {
    static let five = "one\ntwo\nthree\nfour\nfive\n"

    let testDescription: String
    var text = RangeAnswer.five
    let ranges: [LineRange]
    let answer: String

    /// Answers that change a line outside their ranges.
    static let reachingPast = [
        RangeAnswer(testDescription: "a line put in front, as a script that prints one does",
                    ranges: [LineRange(3, 3)], answer: "formatting\none\ntwo\nTHREE\nfour\nfive\n"),
        RangeAnswer(testDescription: "a line below the range changed", ranges: [LineRange(2, 2)], answer: "one\nTWO\nthree\nFOUR\nfive\n"),
        RangeAnswer(testDescription: "a line between two ranges changed",
                    ranges: [LineRange(1, 1), LineRange(5, 5)], answer: "ONE\ntwo\nTHREE\nfour\nFIVE\n"),
        RangeAnswer(testDescription: "a line above the range changed", ranges: [LineRange(3, 3)], answer: "ONE\ntwo\nTHREE\nfour\nfive\n"),
        RangeAnswer(testDescription: "the lines between two ranges in another order",
                    ranges: [LineRange(1, 1), LineRange(5, 5)], answer: "ONE\nthree\ntwo\nfour\nFIVE\n"),
        RangeAnswer(testDescription: "a line between two ranges gone", ranges: [LineRange(1, 1), LineRange(5, 5)], answer: "ONE\ntwo\nfour\nFIVE\n"),
        RangeAnswer(testDescription: "the lines between two ranges with a line put among them",
                    ranges: [LineRange(1, 1), LineRange(5, 5)], answer: "ONE\ntwo\nthree\nextra\nfour\nFIVE\n"),
        RangeAnswer(testDescription: "the last line gone", ranges: [LineRange(2, 2)], answer: "one\nTWO\nthree\nfour\n"),
        RangeAnswer(testDescription: "a newline put after a last line that had none", text: "one\ntwo\nthree",
                    ranges: [LineRange(1, 1)], answer: "ONE\ntwo\nthree\n"),
        RangeAnswer(testDescription: "a line ending changed outside the range", ranges: [LineRange(2, 2)], answer: "one\r\nTWO\nthree\nfour\nfive\n"),
        RangeAnswer(testDescription: "one line standing for the line before the range and the line after it", text: "same\nx\nsame\n",
                    ranges: [LineRange(2, 2)], answer: "same\n"),
        RangeAnswer(testDescription: "one line standing for the line before the first range and the line between the two", text: "same\nx\nsame\ny\n",
                    ranges: [LineRange(2, 2), LineRange(4, 4)], answer: "same\nX\nY\n"),
        RangeAnswer(testDescription: "one line standing for the line between two ranges and the line after the last", text: "x\nsame\ny\nsame\n",
                    ranges: [LineRange(1, 1), LineRange(3, 3)], answer: "X\nY\nsame\n"),
    ]

    /// Answers that change their ranges and nothing else.
    static let keeping = [
        RangeAnswer(testDescription: "a range that comes back as more lines", ranges: [LineRange(3, 3)], answer: "one\ntwo\nthree a\nthree b\nfour\nfive\n"),
        RangeAnswer(testDescription: "a range that comes back as fewer lines", ranges: [LineRange(2, 4)], answer: "one\ntwo three four\nfive\n"),
        RangeAnswer(testDescription: "a range that comes back as no lines", ranges: [LineRange(3, 3)], answer: "one\ntwo\nfour\nfive\n"),
        RangeAnswer(testDescription: "a range that is the first line", ranges: [LineRange(1, 1)], answer: "ONE\ntwo\nthree\nfour\nfive\n"),
        RangeAnswer(testDescription: "a range that is the last line", ranges: [LineRange(5, 5)], answer: "one\ntwo\nthree\nfour\nFIVE\n"),
        RangeAnswer(testDescription: "a last line with no newline, outside the range", text: "one\ntwo\nthree",
                    ranges: [LineRange(1, 1)], answer: "ONE\ntwo\nthree"),
        RangeAnswer(testDescription: "a last line with no newline, in the range", text: "one\ntwo\nthree",
                    ranges: [LineRange(3, 3)], answer: "one\ntwo\nTHREE"),
        RangeAnswer(testDescription: "two ranges, one longer and one gone", ranges: [LineRange(2, 2), LineRange(4, 4)], answer: "one\nTWO\nTWO B\nthree\nfive\n"),
        RangeAnswer(testDescription: "two ranges with no line between them", ranges: [LineRange(2, 2), LineRange(3, 4)], answer: "one\nTWO\nTHREE\nfive\n"),
        RangeAnswer(testDescription: "a range that comes back holding a line like the one after it", text: "a\nb\nsame\nc\nd\n",
                    ranges: [LineRange(2, 2), LineRange(4, 4)], answer: "a\nsame\nsame\nC\nd\n"),
        RangeAnswer(testDescription: "every line in one range", ranges: [LineRange(1, 5)], answer: "all of it\n"),
    ]
}

/// A formatter that was handed lines of a file has to give back every other line of it: the
/// check by itself, and through `FileFormatter`, which leaves the file as it was when the answer does not hold them.
@Suite struct LinesOutsideRangesTests {
    /// The folder, the file, and the formatter of `FileFormatterTests`.
    let files: FileFormatterTests

    init() throws { files = try FileFormatterTests() }

    /// `given` through a formatter that answers as it says: what became of the file, and the file's text afterwards.
    func format(_ given: RangeAnswer, check: Bool = false, joins: Bool = false) async throws -> (file: FormattedFile, text: String) {
        try files.write(given.text)
        var tool = StubFormatter { _ in given.answer }
        tool.joinsToLineAbove = joins
        let file = try await files.formatter(tool, check: check).format("Sources/A.swift", .lines(given.ranges))
        return (file, try files.read())
    }

    static func refusal(_ lines: String) -> [String] {
        ["Sources/A.swift: the formatter changed lines other than \(lines), which it was given, so the file was left as it was"]
    }

    @Test(arguments: RangeAnswer.reachingPast)
    func anAnswerThatChangesAnotherLineDoesNotHoldTheLinesOutsideItsRanges(_ given: RangeAnswer) {
        defer { files.cleanUp() }
        #expect(!FileFormatter.holds(given.answer, linesOutside: given.ranges, of: given.text))
    }

    @Test(arguments: RangeAnswer.keeping)
    func anAnswerThatChangesOnlyItsRangesHoldsTheLinesOutsideThem(_ given: RangeAnswer) {
        defer { files.cleanUp() }
        #expect(FileFormatter.holds(given.answer, linesOutside: given.ranges, of: given.text))
    }

    @Test(arguments: RangeAnswer.reachingPast)
    func aFileWhoseAnswerChangesAnotherLineIsLeftAsItWas(_ given: RangeAnswer) async throws {
        defer { files.cleanUp() }
        let (file, text) = try await format(given)
        #expect(text == given.text)
        #expect(file.lines == nil && file.note == nil)
        #expect(file.failure?.count == 1 && file.failure?.first?.hasPrefix("Sources/A.swift: the formatter changed lines other than line") == true)
    }

    @Test(arguments: RangeAnswer.keeping)
    func aFileWhoseAnswerChangesOnlyItsRangesIsWritten(_ given: RangeAnswer) async throws {
        defer { files.cleanUp() }
        let (file, text) = try await format(given)
        #expect(text == given.answer)
        #expect(file.failure == nil && file.lines?.isEmpty == false)
    }

    /// The ranges are named as a result lists a file's lines: `line 4` for one, `lines 4, 27-29` for several.
    @Test func theLineOfSuchAFileNamesTheRangesTheFormatterWasGiven() async throws {
        defer { files.cleanUp() }
        let inFront = try await format(RangeAnswer.reachingPast[0])
        #expect(inFront.file.failure == Self.refusal("line 3"))
        let below = try await format(RangeAnswer.reachingPast[1])
        #expect(below.file.failure == Self.refusal("line 2"))
        let between = try await format(RangeAnswer.reachingPast[2])
        #expect(between.file.failure == Self.refusal("lines 1, 5"))
        let several = RangeAnswer(testDescription: "", ranges: [LineRange(1, 1), LineRange(3, 4)], answer: "ONE\ntwo\nTHREE\nfour\nFIVE\n")
        #expect(try await format(several).file.failure == Self.refusal("lines 1, 3-4"))
        let run = RangeAnswer(testDescription: "", ranges: [LineRange(2, 3)], answer: "ONE\nTWO\nthree\nfour\nfive\n")
        #expect(try await format(run).file.failure == Self.refusal("lines 2-3"))
    }

    /// A check writes nothing either way, and must not list lines of an answer that would not be written.
    @Test func aCheckListsSuchAFileAsOneThatCouldNotBeProcessedToo() async throws {
        defer { files.cleanUp() }
        let (file, text) = try await format(RangeAnswer.reachingPast[0], check: true)
        #expect(text == RangeAnswer.five && file.lines == nil && file.failure == Self.refusal("line 3"))
    }

    /// Through `xcd format`, with what a `format.path` script that prints a line of its own before swift-format's text
    /// gives: the changed file is listed and left as it was, and the command fails.
    @Test func xcdFormatListsAFileWhoseFormatterPrintedALineOfItsOwn() async throws {
        let project = try FormatProject(FormatProject.appleSwiftFormat)
        defer { project.project.remove() }
        defer { files.cleanUp() }
        try project.change()
        let changed = try project.read("Sources/App/A.swift")
        let ctx = try await project.context()
        let service = project.service(FakeFormatters())
        project.fake.stub(["swift-format"]) { call in
            let file = (try? String(contentsOfFile: call.arguments.last ?? "", encoding: .utf8)) ?? ""
            return ProcessOutput(exitCode: 0, stdout: "formatting\n" + file, stderr: "")
        }
        let report = try await service.format(FormatOptions(paths: ["Sources/App/A.swift"]), in: ctx)
        #expect(try project.read("Sources/App/A.swift") == changed)
        #expect(report.failed == [FormatReport.Failed(file: "Sources/App/A.swift", message: Self.refusal("line 7")[0].replacingOccurrences(
            of: "Sources/A.swift", with: "Sources/App/A.swift"))])
        #expect(report.changed.isEmpty && report.failure?.code == .formatFailed && report.failure?.code.exitCode == 1)
    }

    /// SwiftFormat joins the first line of a range to the line above it, and holds that line to account itself after
    /// each pass (`SwiftFormatTool.keepsLinesAbove`). For such a formatter the line directly above each range is not
    /// held against the answer here; for any other it is.
    @Test func aFormatterThatJoinsToTheLineAboveMayChangeThatLine() async throws {
        defer { files.cleanUp() }
        let joined = RangeAnswer(testDescription: "", ranges: [LineRange(3, 3)], answer: "one\ntwo three\nfour\nfive\n")
        let strict = try await format(joined)
        #expect(strict.text == RangeAnswer.five && strict.file.failure == Self.refusal("line 3"))
        let taken = try await format(joined, joins: true)
        #expect(taken.text == joined.answer && taken.file.failure == nil && taken.file.lines == [LineRange(2, 2)])
        let both = RangeAnswer(testDescription: "", ranges: [LineRange(2, 2), LineRange(5, 5)], answer: "one two\nthree\nfour five\n")
        let two = try await format(both, joins: true)
        #expect(two.text == both.answer && two.file.failure == nil && two.file.lines == [LineRange(1, 1), LineRange(3, 3)])
        let check = try await format(joined, check: true, joins: true)
        #expect(check.text == RangeAnswer.five && check.file.failure == nil && check.file.lines == [LineRange(2, 3)])
    }

    /// The line directly above is the only one let go: a line further up, a line below, and a line put in front are
    /// held against such a formatter's answer as against any other's.
    @Test(arguments: [0, 1, 3, 5, 7])
    func aFormatterThatJoinsToTheLineAboveMayChangeNoOtherLine(_ index: Int) async throws {
        defer { files.cleanUp() }
        let given = RangeAnswer.reachingPast[index]
        let (file, text) = try await format(given, joins: true)
        #expect(text == given.text && file.lines == nil, "\(given.testDescription)")
        #expect(file.failure?.first?.hasPrefix("Sources/A.swift: the formatter changed lines other than line") == true, "\(given.testDescription)")
        let twoUp = RangeAnswer(testDescription: "", ranges: [LineRange(2, 2), LineRange(5, 5)], answer: "one\nTWO\nTHREE\nfour\nFIVE\n")
        #expect(try await format(twoUp, joins: true).file.failure == Self.refusal("lines 2, 5"))
    }

    /// Through `xcd format`, with what SwiftFormat gives for a changed line that starts with a comma: the comma at
    /// the end of the line above, which the change did not touch. The file is written, and both lines are listed.
    @Test func xcdFormatWritesAFileWhoseChangedLineSwiftFormatJoinedToTheLineAbove() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        defer { files.cleanUp() }
        let edited = FormatProject.base.replacingOccurrences(of: "    let d = 4\n", with: "    let d = 4\n    , e = 5\n")
        let joined = FormatProject.base.replacingOccurrences(of: "    let d = 4\n", with: "    let d = 4,\n        e = 5\n")
        try project.project.write(edited, to: "Sources/App/A.swift")
        let ctx = try await project.context()
        let service = project.service(FakeFormatters())
        project.fake.stub(["swiftformat"], stdout: joined)
        let report = try await service.format(FormatOptions(paths: ["Sources/App/A.swift"]), in: ctx)
        #expect(try project.read("Sources/App/A.swift") == joined)
        #expect(report.failure == nil && report.failed.isEmpty, "\(report.text)")
        #expect(report.changed.map(\.lines) == [[LineRange(7, 8)]])
        #expect(project.fake.calls.last?.arguments.contains("8,8") == true)
    }

    /// There is nothing to hold an answer for a whole file against: it is written as the formatter gave it.
    @Test func aFileHandedOverWholeIsNotChecked() async throws {
        defer { files.cleanUp() }
        try files.write(RangeAnswer.five)
        let file = try await files.formatter(StubFormatter { _ in "formatting\n" + RangeAnswer.five }).format("Sources/A.swift", .whole)
        #expect(try files.read() == "formatting\n" + RangeAnswer.five)
        #expect(file.failure == nil && file.lines == [LineRange(1, 1)])
    }
}
