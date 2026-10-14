import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// A formatter that answers from a closure, and remembers what it was asked.
struct StubFormatter: FormatterTool {
    let jobs = Shared<[FormatJob]>([])
    let answer: @Sendable (FormatJob) throws -> FormatAnswer
    /// Whether it stands for a formatter that joins a range's first line to the line above, as SwiftFormat does.
    var joinsToLineAbove = false

    /// Answers every job with `text` applied to the job's text. Nil is a formatter that could not process the file.
    init(said: [String] = [], _ text: @escaping @Sendable (String) -> String?) {
        answer = { FormatAnswer(text: text($0.text), said: said, transcript: "$ formatter \($0.path)\n") }
    }

    func format(_ job: FormatJob) async throws -> FormatAnswer {
        jobs.change { $0.append(job) }
        return try answer(job)
    }
}

/// One file from disk, through a formatter, and back. The formatter is `StubFormatter`.
@Suite struct FileFormatterTests {
    static let source = "struct A {\n  let a = 1\n  let b = 2\n}\n"
    /// What the stand-in formatter makes of `source`: four spaces, and a comment put on top.
    static let formatted = "// formatted\nstruct A {\n    let a = 1\n    let b = 2\n}\n"

    let root: String

    init() throws {
        root = Paths.canonical(NSTemporaryDirectory()) + "/xcd-fileformatter-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/Sources", withIntermediateDirectories: true)
    }

    /// A formatter that indents with four spaces and puts a comment on top.
    static func reindent() -> StubFormatter {
        StubFormatter { "// formatted\n" + $0.replacingOccurrences(of: "\n  let", with: "\n    let") }
    }

    func formatter(_ tool: StubFormatter = FileFormatterTests.reindent(), check: Bool = false, interrupts: Interrupts = Interrupts()) -> FileFormatter {
        FileFormatter(tool: tool, worktreeRoot: root, check: check, interrupts: interrupts)
    }

    func write(_ text: String = FileFormatterTests.source, to path: String = "Sources/A.swift") throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: root + "/" + path))
    }

    func read(_ path: String = "Sources/A.swift") throws -> String {
        try String(contentsOfFile: root + "/" + path, encoding: .utf8)
    }

    func cleanUp() { try? FileManager.default.removeItem(atPath: root) }

    @Test func aFileTheFormatterChangesIsWrittenAndItsNewLinesAreListed() async throws {
        defer { cleanUp() }
        try write()
        let tool = Self.reindent()
        let file = try await formatter(tool).format("Sources/A.swift", .whole)
        #expect(try read() == Self.formatted)
        #expect(file.lines == [LineRange(1, 1), LineRange(3, 4)] && file.failure == nil && file.note == nil)
        #expect(tool.jobs.value == [FormatJob(path: "Sources/A.swift", text: Self.source, ranges: nil)])
        #expect(file.transcript == "$ formatter Sources/A.swift\n")
    }

    /// The lines are numbered in the file a person has in front of them: after a check, the file as it still is.
    @Test func aCheckWritesNothingAndListsTheLinesAsTheyAre() async throws {
        defer { cleanUp() }
        try write()
        let file = try await formatter(check: true).format("Sources/A.swift", .whole)
        #expect(try read() == Self.source)
        #expect(file.lines == [LineRange(1, 3)])              // the comment would go in before line 1, and lines 2 and 3 would change
    }

    @Test func onlyTheChangedLinesAreHandedToTheFormatter() async throws {
        defer { cleanUp() }
        try write()
        let tool = Self.reindent()
        _ = try await formatter(tool).format("Sources/A.swift", .lines([LineRange(2, 2), LineRange(4, 4)]))
        #expect(tool.jobs.value.first?.ranges == [LineRange(2, 2), LineRange(4, 4)])
    }

    /// A file the change only renamed, or only took lines out of, has no line to format.
    @Test func aFileWithNoChangedLinesIsNotRead() async throws {
        defer { cleanUp() }
        let tool = Self.reindent()
        let file = try await formatter(tool).format("Sources/Missing.swift", .lines([]))
        #expect(file == FormattedFile(path: "Sources/Missing.swift") && tool.jobs.value.isEmpty)
    }

    @Test func aFileThatIsAsTheFormatterWantsItIsNotWritten() async throws {
        defer { cleanUp() }
        try write(Self.formatted)
        let before = try FileManager.default.attributesOfItem(atPath: root + "/Sources/A.swift")[.systemFileNumber] as? Int
        let file = try await formatter(StubFormatter(said: ["warning: a rule is unknown"]) { $0 }).format("Sources/A.swift", .whole)
        #expect(file.lines == nil && file.failure == nil && file.said == ["warning: a rule is unknown"])
        #expect(try FileManager.default.attributesOfItem(atPath: root + "/Sources/A.swift")[.systemFileNumber] as? Int == before)
    }

    /// SwiftFormat returns such a file with the bad byte replaced by three others. It is never handed over.
    @Test func aFileThatIsNotUTF8IsNotHandedToTheFormatter() async throws {
        defer { cleanUp() }
        let latin1 = Data("// caf".utf8) + Data([0xE9, 0x0A]) + Data(Self.source.utf8)
        try latin1.write(to: URL(fileURLWithPath: root + "/Sources/A.swift"))
        let tool = Self.reindent()
        let file = try await formatter(tool).format("Sources/A.swift", .whole)
        #expect(file.failure == ["Sources/A.swift: is not valid UTF-8, so it was not given to the formatter"] && file.lines == nil)
        #expect(tool.jobs.value.isEmpty)
        #expect(try Data(contentsOf: URL(fileURLWithPath: root + "/Sources/A.swift")) == latin1)
    }

    /// Given lines of a file with CRLF endings, swift-format takes the indentation off the first of them and
    /// SwiftFormat takes the line ending off the line above. Such a file is formatted whole or not at all.
    @Test func aFileWithWindowsLineEndingsIsNotFormattedByLines() async throws {
        defer { cleanUp() }
        let windows = Self.source.replacingOccurrences(of: "\n", with: "\r\n")
        try write(windows)
        let tool = Self.reindent()
        let byLines = try await formatter(tool).format("Sources/A.swift", .lines([LineRange(2, 2)]))
        #expect(byLines.failure == ["Sources/A.swift: has Windows line endings (CRLF), and a formatter given lines of such a file damages the lines around them, so it was left as it was; `xcd format --files` formats the file whole"])
        #expect(tool.jobs.value.isEmpty)
        #expect(try read() == windows)
        let whole = try await formatter(StubFormatter { $0.replacingOccurrences(of: "\r\n", with: "\n") }).format("Sources/A.swift", .whole)
        #expect(whole.failure == nil && whole.lines == [LineRange(1, 4)])
        #expect(try read() == Self.source)                                           // written as the formatter returned it
    }

    /// The formatter's own lines are kept. swift-format names the file by its full path; SwiftFormat names no file.
    @Test func aFileTheFormatterCouldNotProcessIsLeftAsItWasWithTheFormattersLines() async throws {
        defer { cleanUp() }
        try write()
        let said = ["\(root)/Sources/A.swift:2:10: error: expected ')' to end parameter clause", "error: Unexpected end of file at 4:1.",
                    "<unknown>: error: Unable to read configuration for Sources/A.swift: The given data was not valid JSON."]
        let file = try await formatter(StubFormatter(said: said) { _ in nil }).format("Sources/A.swift", .whole)
        #expect(file.failure == [
            "Sources/A.swift:2:10: error: expected ')' to end parameter clause",
            "Sources/A.swift: error: Unexpected end of file at 4:1.",
            "<unknown>: error: Unable to read configuration for Sources/A.swift: The given data was not valid JSON.",
        ])
        #expect(file.lines == nil && file.said.isEmpty)
        #expect(try read() == Self.source)
    }

    @Test func beyondFiveLinesTheResultSaysHowManyMoreTheLogHolds() async throws {
        defer { cleanUp() }
        try write()
        let file = try await formatter(StubFormatter(said: (1...7).map { "error: number \($0)" }) { _ in nil }).format("Sources/A.swift", .whole)
        #expect(file.failure?.count == 6 && file.failure?.first == "Sources/A.swift: error: number 1")
        #expect(file.failure?.last == "Sources/A.swift: 2 more lines are in the log")
        let six = try await formatter(StubFormatter(said: (1...6).map { "error: number \($0)" }) { _ in nil }).format("Sources/A.swift", .whole)
        #expect(six.failure?.last == "Sources/A.swift: 1 more line is in the log")
    }

    /// Someone saved the file while the formatter ran: what the formatter returned is for a text that is gone.
    @Test func aFileThatChangedWhileTheFormatterRanIsLeftAlone() async throws {
        defer { cleanUp() }
        try write()
        let path = root + "/Sources/A.swift"
        let tool = StubFormatter { text in
            try? Data("// saved meanwhile\n".utf8).write(to: URL(fileURLWithPath: path))
            return text + "// formatted\n"
        }
        let file = try await formatter(tool).format("Sources/A.swift", .whole)
        #expect(try read() == "// saved meanwhile\n")
        #expect(file.lines == nil && file.failure == nil)
        #expect(file.note == "Sources/A.swift changed while it was being formatted, so it was left as it was")
    }

    @Test func theWriteKeepsTheFilesPermissionsAndLeavesNothingBesideIt() async throws {
        defer { cleanUp() }
        try write()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/Sources/A.swift")
        _ = try await formatter().format("Sources/A.swift", .whole)
        #expect(try read() == Self.formatted)
        #expect(try FileManager.default.attributesOfItem(atPath: root + "/Sources/A.swift")[.posixPermissions] as? Int == 0o755)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: root).sorted() == ["Sources", "Sources/A.swift"])
    }

    @Test func onceXcdWasInterruptedNoFileIsWritten() async throws {
        defer { cleanUp() }
        try write()
        let interrupts = LintFolderTests.quietInterrupts()
        #expect(interrupts.handle(SIGINT) == 130)
        let file = try await formatter(interrupts: interrupts).format("Sources/A.swift", .whole)
        #expect(try read() == Self.source)
        #expect(file.lines == nil && file.note == "Sources/A.swift was not written, because xcd was interrupted, so it was left as it was")
    }

    /// A folder that takes no new file takes no atomic write. The file is as it was, and the result says why.
    @Test func aFileThatCannotBeWrittenIsListedAndStaysAsItWas() async throws {
        defer { cleanUp() }
        try write()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root + "/Sources")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/Sources") }
        let file = try await formatter().format("Sources/A.swift", .whole)
        #expect(file.lines == nil && file.failure?.count == 1)
        #expect(file.failure?.first?.hasPrefix("Sources/A.swift: could not be written: ") == true)
        #expect(try read() == Self.source)
    }

    @Test func aFileThatCannotBeReadIsOneThatCouldNotBeProcessed() async throws {
        defer { cleanUp() }
        let file = try await formatter().format("Sources/Gone.swift", .whole)
        #expect(file.failure == ["Sources/Gone.swift: could not be read"])
    }

    // MARK: a leading byte order mark stays, and an empty answer is never written over text

    static let mark = Data([0xEF, 0xBB, 0xBF])

    /// Indents only line 3, so line 1 is untouched whatever the scope.
    static func indentLineThree() -> StubFormatter {
        StubFormatter { $0.replacingOccurrences(of: "\n  let b", with: "\n    let b") }
    }

    func writeWithMark(_ text: String = FileFormatterTests.source) throws {
        try (Self.mark + Data(text.utf8)).write(to: URL(fileURLWithPath: root + "/Sources/A.swift"))
    }

    func bytes() throws -> Data { try Data(contentsOf: URL(fileURLWithPath: root + "/Sources/A.swift")) }

    @Test func aByteOrderMarkStaysWhenTheFileIsFormattedByLines() async throws {
        defer { cleanUp() }
        try writeWithMark()
        let tool = Self.indentLineThree()
        let file = try await formatter(tool).format("Sources/A.swift", .lines([LineRange(3, 3)]))
        let expected = "struct A {\n  let a = 1\n    let b = 2\n}\n"
        #expect(try bytes() == Self.mark + Data(expected.utf8))
        #expect(file.lines == [LineRange(3, 3)] && file.failure == nil)
        #expect(tool.jobs.value.first?.text == Self.source)
    }

    @Test func aByteOrderMarkStaysWhenTheFileIsFormattedWhole() async throws {
        defer { cleanUp() }
        try writeWithMark()
        let file = try await formatter().format("Sources/A.swift", .whole)
        #expect(try bytes() == Self.mark + Data(Self.formatted.utf8))
        #expect(file.lines == [LineRange(1, 1), LineRange(3, 4)])
    }

    /// SwiftFormat gives a mark back when it is handed one. It is not a difference, and it is not kept twice.
    @Test func aMarkTheFormatterGivesBackIsNotADifferenceAndNotKeptTwice() async throws {
        defer { cleanUp() }
        try writeWithMark(Self.formatted)
        let before = try bytes()
        let tidy = try await formatter(StubFormatter { "\u{FEFF}" + $0 }).format("Sources/A.swift", .whole)
        #expect(tidy.lines == nil && tidy.failure == nil)
        #expect(try bytes() == before)
        try writeWithMark()
        _ = try await formatter(StubFormatter { "\u{FEFF}" + Self.formatted + $0.prefix(0) }).format("Sources/A.swift", .whole)
        #expect(try bytes() == Self.mark + Data(Self.formatted.utf8))
    }

    @Test func aFileWithoutAMarkGetsNone() async throws {
        defer { cleanUp() }
        try write()
        _ = try await formatter(StubFormatter { "\u{FEFF}" + Self.formatted + $0.prefix(0) }).format("Sources/A.swift", .whole)
        #expect(try bytes() == Data(Self.formatted.utf8))
    }

    @Test func aCheckOfAFileWithAMarkListsTheLinesTheWriteListsAndWritesNothing() async throws {
        defer { cleanUp() }
        try writeWithMark()
        let before = try bytes()
        let checked = try await formatter(check: true).format("Sources/A.swift", .whole)
        #expect(try bytes() == before)
        try writeWithMark()
        let written = try await formatter().format("Sources/A.swift", .whole)
        #expect(checked.lines == [LineRange(1, 3)] && written.lines == [LineRange(1, 1), LineRange(3, 4)])
        try writeWithMark()
        let byLines = try await formatter(Self.indentLineThree(), check: true).format("Sources/A.swift", .lines([LineRange(3, 3)]))
        #expect(byLines.lines == [LineRange(3, 3)])
        #expect(try bytes() == before)
    }

    @Test func aFileThatIsTidyButForItsMarkIsNotWrittenAndNotListed() async throws {
        defer { cleanUp() }
        try writeWithMark()
        let before = try bytes()
        let file = try await formatter(StubFormatter { $0 }).format("Sources/A.swift", .whole)
        #expect(file.lines == nil && file.failure == nil)
        #expect(try bytes() == before)
    }

    @Test func anEmptyAnswerForAFileWithTextLeavesTheFileAsItIs() async throws {
        defer { cleanUp() }
        try write()
        let file = try await formatter(StubFormatter { _ in "" }).format("Sources/A.swift", .whole)
        #expect(file.lines == nil && file.failure == nil && file.note == nil)
        #expect(try bytes() == Data(Self.source.utf8))
    }
}
