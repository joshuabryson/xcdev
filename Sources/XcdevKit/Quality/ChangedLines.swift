import Foundation

/// A run of lines in a file, numbered from 1, its first and last line both included.
public struct LineRange: Sendable, Equatable, Encodable {
    public let first: Int
    public let last: Int

    public init(_ first: Int, _ last: Int) {
        self.first = first
        self.last = last
    }

    /// `40-47`, or `120` for one line.
    public var text: String { first == last ? "\(first)" : "\(first)-\(last)" }

    /// In JSON a range is the pair `[first, last]`.
    public func encode(to encoder: any Encoder) throws {
        var pair = encoder.unkeyedContainer()
        try pair.encode(first)
        try pair.encode(last)
    }
}

extension [LineRange] {
    /// How a result names lines of a file: `line 12` for one line, else `lines 88-91, 120`.
    var named: String {
        let one = count == 1 && first?.first == first?.last
        return "line\(one ? "" : "s") " + map(\.text).joined(separator: ", ")
    }
}

/// How much of a file a change touched.
public enum ChangedPart: Sendable, Equatable {
    /// Every line: the fork point has no such file.
    case whole
    /// These lines, in order. None for a file the change only renamed, or only took lines out of.
    case lines([LineRange])
}

/// Finds the lines of a file that the working tree changed against the fork point.
public struct ChangedLines: Sendable {
    /// What every diff is asked with, so that the person's git settings, their `GIT_DIFF_OPTS`, and a file git would
    /// call binary change nothing that comes back: no lines around a change, none between two changes, renames
    /// followed, every file read as text, and no colour, outside diff program, or text conversion. Not covered: a
    /// clean filter that changes the number of lines (`filter.<name>.clean`), since git diffs the cleaned text.
    static let options = ["diff", "-U0", "--inter-hunk-context=0", "-M", "--text", "--no-color", "--no-ext-diff", "--no-textconv"]

    /// git reads this after the command line, so it is set for the process, over the person's own.
    static let environment = ["GIT_DIFF_OPTS": "-u0"]

    public let runner: any ProcessRunning

    public init(runner: any ProcessRunning) { self.runner = runner }

    /// The part of `file` that differs from the fork point: committed, staged, and unstaged edits together. The
    /// diff is asked for this one file, by its old and new path, so no file name is read out of git's output.
    public func part(of file: ScopedFile, in root: String, since forkPoint: String) async throws -> ChangedPart {
        guard let basePath = file.basePath else { return .whole }
        let paths = basePath == file.path ? [basePath] : [basePath, file.path]
        var invocation = Invocation.git(["--literal-pathspecs"] + Self.options + [forkPoint, "--"] + paths, in: root)
        invocation.environment = Self.environment
        let diff = try await runner.runChecked(invocation)
        return Self.parse(diff.stdoutString)
    }

    /// One file's diff as its changed part. A line ends at `\n` or `\r\n`, which Swift counts as one character, so a
    /// carriage return that git prints at the end of a line of the file does not hide the header after it. The lines
    /// of the file itself all start with a space, `+`, `-`, or `\` there, so a line that starts with `@@` is a hunk's
    /// header and nothing else. A diff that says a file was removed is of a path that was a link at the fork point,
    /// or that git no longer tracks: what is on disk now has no earlier version to be compared with line by line.
    static func parse(_ diff: String) -> ChangedPart {
        let lines = diff.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        if lines.contains(where: { $0.hasPrefix("deleted file mode") }) { return .whole }
        return .lines(lines.compactMap(range(ofHunk:)))
    }

    /// The new side of a hunk header. `@@ -2 +2 @@` is line 2, `@@ -6,0 +6,2 @@` is lines 6 to 7, and
    /// `@@ -4 +3,0 @@` only removes lines, so it has none. Nil for any other line.
    static func range(ofHunk line: Substring) -> LineRange? {
        let words = line.split(separator: " ")
        guard words.count >= 4, words[0] == "@@", words[3] == "@@", words[2].hasPrefix("+") else { return nil }
        let numbers = words[2].dropFirst().split(separator: ",").map { Int($0) }
        guard let first = numbers.first ?? nil, let count = numbers.count > 1 ? numbers[1] : 1, count > 0 else { return nil }
        return LineRange(first, first + count - 1)
    }
}
