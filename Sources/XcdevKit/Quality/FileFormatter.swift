import Foundation

/// What `xcd format` did with one file.
public struct FormattedFile: Sendable, Equatable {
    /// Relative to the worktree root.
    public let path: String
    /// The lines that differ, when the formatter changed the file: numbered in the file as it was written, or with
    /// `--check` in the file as it is. Nil for a file that is as the formatter wants it, or that was left alone.
    public var lines: [LineRange]?
    /// Why the file could not be processed, as lines for the result. Nil when it could.
    public var failure: [String]?
    /// Something the result should say about the file though nothing failed.
    public var note: String?
    /// What the formatter wrote to stderr while it worked.
    public var said: [String] = []
    /// Each run's command and what it gave, for the log.
    public var transcript = ""

    public init(path: String) { self.path = path }
}

/// Formats one file of the worktree: reads it, asks the formatter for the formatted text, and
/// writes that when it differs. The formatter writes nothing itself.
struct FileFormatter: Sendable {
    /// How many of a formatter's lines about one file the result carries. The log has them all.
    static let mostLines = 5

    /// A file as xcd read it.
    struct Source {
        let url: URL
        let data: Data
        /// The file's text without a leading byte order mark.
        let text: String
        let hasMark: Bool
    }

    /// The UTF-8 byte order mark. It is not text for a formatter to have an opinion on, so it stays as it is.
    static let byteOrderMark = Data([0xEF, 0xBB, 0xBF])

    /// A file's bytes as text, the mark taken off explicitly. Nil when they are not valid UTF-8.
    static func decode(_ data: Data, url: URL) -> Source? {
        let hasMark = data.starts(with: byteOrderMark)
        guard let text = String(data: hasMark ? data.dropFirst(byteOrderMark.count) : data, encoding: .utf8) else { return nil }
        return Source(url: url, data: data, text: text, hasMark: hasMark)
    }

    let tool: any FormatterTool
    let worktreeRoot: String
    /// `--check`: nothing is written.
    let check: Bool
    let interrupts: Interrupts

    /// `part` is how much of the file to format: all of it, or the lines the change touched.
    func format(_ path: String, _ part: ChangedPart) async throws -> FormattedFile {
        var file = FormattedFile(path: path)
        guard part != .lines([]) else { return file }
        let url = URL(fileURLWithPath: worktreeRoot + "/" + path)
        guard let data = try? Data(contentsOf: url) else { return failed(file, ["could not be read"]) }
        guard let source = Self.decode(data, url: url) else {
            return failed(file, ["is not valid UTF-8, so it was not given to the formatter"])
        }
        let text = source.text
        var ranges: [LineRange]?
        if case .lines(let changed) = part {
            guard !text.utf8.contains(UInt8(ascii: "\r")) else { return failed(file, [Self.windowsEndings]) }
            ranges = changed
        }
        let answer = try await tool.format(FormatJob(path: path, text: text, ranges: ranges))
        file.transcript = answer.transcript
        guard let given = answer.text else { return failed(file, answer.said) }
        file.said = answer.said
        return take(given, for: ranges, of: source, file)
    }

    /// What becomes of `file` with the formatter's text for it: left as it is when the answer changes nothing, listed
    /// as one that could not be processed when an answer for `ranges` changed a line outside them, and written
    /// otherwise. An answer for a whole file, with no ranges, has nothing to be held against.
    func take(_ answer: String, for ranges: [LineRange]?, of source: Source, _ file: FormattedFile) -> FormattedFile {
        guard let formatted = Self.change(answer, to: source.text) else { return file }
        if let ranges, !Self.holds(formatted, linesOutside: ranges, of: source.text) { return failed(file, [Self.reachedPast(ranges)]) }
        return write(formatted, over: source, file)
    }

    /// What to write for the formatter's answer: nil when the file stays as it is, because the answer is the same
    /// text or is empty for a file that has text. A mark the formatter gave back is taken off.
    static func change(_ answer: String, to text: String) -> String? {
        var answer = answer
        if answer.unicodeScalars.first == "\u{FEFF}" { answer.unicodeScalars.removeFirst() }
        return answer == text || (answer.isEmpty && !text.isEmpty) ? nil : answer
    }

    /// Why a file with a carriage return is not formatted by lines. Both formatters damage such a file around the
    /// range they are given: swift-format takes the indentation off the range's first line, and SwiftFormat takes
    /// the line ending off the line above it.
    static let windowsEndings = "has Windows line endings (CRLF), and a formatter given lines of such a file damages the lines "
        + "around them, so it was left as it was; `xcd format --files` formats the file whole"

    /// The file with the formatter's change: listed, and written unless this is a check. Before writing, the file is
    /// read again: when it is no longer what the formatter was given, it is left alone and the result says so. The
    /// write replaces the file in one step and does not start once xcd was interrupted. The file is a new one under the
    /// old name: its mode bits are kept, but not its extended attributes (Finder tags), ACL or creation date, its group
    /// becomes the folder's, and a hard link's twin keeps the old text. Both formatters do the same.
    func write(_ formatted: String, over source: Source, _ file: FormattedFile) -> FormattedFile {
        var file = file
        let diff = LineDiff(from: source.text, to: formatted)
        guard !check else {
            file.lines = diff.oldLines
            return file
        }
        var failure: (any Error)?
        var current: Data?
        let ran = interrupts.perform {
            current = try? Data(contentsOf: source.url)
            guard current == source.data else { return }
            do { try ((source.hasMark ? Self.byteOrderMark : Data()) + Data(formatted.utf8)).write(to: source.url, options: .atomic) } catch { failure = error }
        }
        if let failure { return failed(file, ["could not be written: \(failure.localizedDescription)"]) }
        if ran, current == source.data {
            file.lines = diff.newLines
        } else {
            file.note = "\(file.path) \(ran ? "changed while it was being formatted" : "was not written, because xcd was interrupted"), so it was left as it was"
        }
        return file
    }

    /// `file` as one that could not be processed. Each of `lines` is put the way the result prints it: the worktree
    /// taken off a full path, and the file's own path in front of a line that does not name it. Beyond `mostLines`
    /// the result says how many more the log holds.
    func failed(_ file: FormattedFile, _ lines: [String]) -> FormattedFile {
        var file = file
        let roots = Set([worktreeRoot, Paths.canonical(worktreeRoot), "/private" + worktreeRoot]).sorted { $0.count > $1.count }
        let named = lines.map { line -> String in
            let relative = roots.reduce(line) { $0.replacingOccurrences(of: $1 + "/", with: "") }
            return relative.contains(file.path) ? relative : file.path + ": " + relative
        }
        let more = named.count - Self.mostLines
        file.failure = Array(named.prefix(Self.mostLines)) + (more > 0 ? ["\(file.path): \(more) more line\(more == 1 ? " is" : "s are") in the log"] : [])
        return file
    }
}

// MARK: An answer for ranges

extension FileFormatter {
    /// What is said of a file whose answer changed a line outside the ranges the formatter was given.
    static func reachedPast(_ ranges: [LineRange]) -> String {
        "the formatter changed lines other than \(ranges.named), which it was given, so the file was left as it was"
    }

    /// A line as `LineDiff` reads it: its bytes with its line ending.
    typealias Line = ArraySlice<UInt8>

    /// Whether `answer`, a formatter's text for `text` handed over with `ranges`, holds every line of `text` outside
    /// the ranges, byte for byte and in order: the lines before the first range are its first lines, the lines after
    /// the last range are its last, and the lines between two ranges stand between them as one unbroken run. What
    /// stands in place of a range may be more lines, fewer, or none. A run between two ranges is taken where it
    /// first stands after the run before it, which leaves the most room for the runs that follow.
    static func holds(_ answer: String, linesOutside ranges: [LineRange], of text: String) -> Bool {
        let kept = runs(outside: ranges, of: LineDiff.lines(of: text))
        var rest = LineDiff.lines(of: answer)[...]
        guard let first = kept.first, let last = kept.last, rest.starts(with: first) else { return false }
        rest = rest.dropFirst(first.count)
        for run in kept.dropFirst().dropLast() where !run.isEmpty {
            guard let found = rest.firstRange(of: run) else { return false }
            rest = rest[found.upperBound...]
        }
        return kept.count == 1 ? rest.isEmpty : rest.count >= last.count && rest.suffix(last.count).elementsEqual(last)
    }

    /// The runs of `lines` that lie outside `ranges`, in order: the lines before the first range, between each two,
    /// and after the last. There is one more run than there are ranges, and a run can have no lines.
    static func runs(outside ranges: [LineRange], of lines: [Line]) -> [ArraySlice<Line>] {
        var runs: [ArraySlice<Line>] = []
        var start = 0
        for range in ranges {
            let end = min(max(range.first - 1, start), lines.count)
            runs.append(lines[start..<end])
            start = min(max(range.last, end), lines.count)
        }
        return runs + [lines[start...]]
    }
}
