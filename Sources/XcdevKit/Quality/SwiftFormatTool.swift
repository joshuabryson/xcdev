import Foundation

/// Nick Lockwood's SwiftFormat.
public struct SwiftFormatTool: FormatterTool {
    /// What xcd passes itself after the file's path and the range: no cache is kept, and only errors are printed.
    static let ownArguments = ["--cache", "ignore", "--quiet"]

    public let runner: any ProcessRunning
    public let executable: String
    /// The project's `format.args`, placed after xcd's own.
    public let args: [String]
    public let worktreeRoot: String
    /// Where the text for SwiftFormat's standard input is put: a process is handed its input as a file.
    public let scratch: ScratchFolder

    public init(runner: any ProcessRunning, executable: String, args: [String], worktreeRoot: String, scratch: ScratchFolder) {
        self.runner = runner
        self.executable = executable
        self.args = args
        self.worktreeRoot = worktreeRoot
        self.scratch = scratch
    }

    /// SwiftFormat applies one range per run, so a file with several goes through once per range, the last range
    /// first, each pass on the text the one before gave. A pass usually leaves the lines above its range as they
    /// were, but in some shapes it joins the range's first line to the line directly above: an `else {` or a
    /// `catch {` alone on its line goes to the `}` above it, a `{` alone on its line to the line above, a comma that
    /// starts a line to the end of the line above, and a `]` alone gives the last element above it a comma. Such a
    /// pass is taken: no line further up moved, so the earlier ranges still name their lines. For any other change
    /// above the range (`keepsLinesAbove`) the file is refused, no further pass runs, and the answer says how to
    /// format the file whole.
    public func format(_ job: FormatJob) async throws -> FormatAnswer {
        var answer = FormatAnswer.untouched(job)
        for range in job.ranges.map({ $0.reversed().map(Optional.some) }) ?? [nil] {
            let given = answer.text ?? job.text
            let pass = try await pass(over: given, range, of: job.path)
            answer.transcript += pass.transcript
            answer.said += pass.said.filter { !answer.said.contains($0) }
            answer.text = pass.text
            guard let formatted = pass.text else { break }
            if let range, !Self.keepsLinesAbove(range, given, formatted) {
                answer.text = nil
                answer.said = [Self.refusal(range)]
                answer.transcript += answer.said[0] + "\n"
                break
            }
        }
        return answer
    }

    /// What is said of a file refused because a pass changed a line above its range in a way that is not taken.
    static func refusal(_ range: LineRange) -> String {
        let named = range.first == range.last ? "line \(range.first)" : "lines \(range.text)"
        return "swiftformat changed a line above \(named), the range it was given, so the file was left as it was; `xcd format --files` formats the file whole"
    }

    /// `swiftformat stdin --stdin-path <file> [--line-range <first>,<last>] --cache ignore --quiet <args…>`, from the
    /// worktree root, with `text` on standard input. SwiftFormat leaves the last token of a text out of a range
    /// when no newline ends the text, and damages it; so a pass with a range is handed a newline that it gives back.
    /// SwiftFormat finds `.swiftformat` from the path given, and
    /// returns a file its config excludes unchanged.
    func pass(over text: String, _ range: LineRange?, of path: String) async throws -> FormatAnswer {
        let input = UUID().uuidString + ".swift"
        let handed = range != nil && !text.isEmpty && text.unicodeScalars.last != "\n" ? text + "\n" : text
        try scratch.write(Data(handed.utf8), to: input)
        defer { Disk.remove(scratch.root + "/" + input) }
        let lines = range.map { ["--line-range", "\($0.first),\($0.last)"] } ?? []
        let invocation = Invocation(executable, ["stdin", "--stdin-path", worktreeRoot + "/" + path] + lines + Self.ownArguments + args,
                                    workingDirectory: worktreeRoot, timeout: FormatAnswer.timeout, inputFile: scratch.root + "/" + input)
        var answer = try await FormatAnswer.from(invocation, given: handed, on: runner)
        if handed != text, answer.text?.unicodeScalars.last == "\n" { answer.text?.unicodeScalars.removeLast() }
        return answer
    }

    /// SwiftFormat joins the first line of a range to the line above it, so `FileFormatter` does not hold that line
    /// against the answer: `keepsLinesAbove` has held it to account after each pass.
    public var joinsToLineAbove: Bool { true }

    /// Whether a pass over `range` left the lines above it as xcd takes them: every line further up than the one
    /// directly above is the same in both texts, byte for byte, and that one is the same or was joined to.
    static func keepsLinesAbove(_ range: LineRange, _ given: String, _ formatted: String) -> Bool {
        let before = LineDiff.lines(of: given).prefix(range.first - 1), after = LineDiff.lines(of: formatted)
        guard let above = before.last else { return true }
        guard after.count >= before.count, after.prefix(before.count - 1) == before.dropLast() else { return false }
        return after[before.count - 1] == above || isJoin(after[before.count - 1], to: above)
    }

    /// Whether `line` is `above` with more at its end, which is what a join leaves: the line keeps every byte it
    /// held but its line ending. Not a join, though SwiftFormat gives both: a blank line that the range's first line
    /// took the place of (a `{` under a blank line comes back without the blank line and without its indentation),
    /// and a line with `//` in it, since what is added after a comment is no longer code (a comma that starts the
    /// range comes back inside the comment above it, and the call no longer compiles).
    static func isJoin(_ line: ArraySlice<UInt8>, to above: ArraySlice<UInt8>) -> Bool {
        let held = above.last == UInt8(ascii: "\n") ? above.dropLast() : above
        let blank = held.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
        let comment = zip(held, held.dropFirst()).contains { $0 == UInt8(ascii: "/") && $1 == UInt8(ascii: "/") }
        return !blank && !comment && line.starts(with: held)
    }
}
