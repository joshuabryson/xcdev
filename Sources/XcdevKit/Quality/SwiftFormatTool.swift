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
    /// were, but in some shapes it changes the line directly above: an `else {` or a `catch {` alone on its line is
    /// joined to the `}` above it, a `{` alone on its line to the line above, and a `]` alone gives the last element
    /// above it a comma. The check after each pass is what keeps xcd from writing a file whose earlier ranges may no
    /// longer name their lines: when a line above the range came back changed, the file is refused, no further pass
    /// runs, and the answer says how to format the file whole.
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

    /// What is said of a file refused because a pass changed a line above its range.
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

    /// Whether the lines above `range` are the same, byte for byte, in both texts.
    static func keepsLinesAbove(_ range: LineRange, _ given: String, _ formatted: String) -> Bool {
        LineDiff.lines(of: given).prefix(range.first - 1) == LineDiff.lines(of: formatted).prefix(range.first - 1)
    }
}
