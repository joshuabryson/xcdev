import Foundation

/// Apple's swift-format, which ships inside Xcode.
public struct AppleSwiftFormatTool: FormatterTool {
    public let runner: any ProcessRunning
    public let executable: String
    /// The project's `format.args`, placed after xcd's own.
    public let args: [String]
    public let worktreeRoot: String

    public init(runner: any ProcessRunning, executable: String, args: [String], worktreeRoot: String) {
        self.runner = runner
        self.executable = executable
        self.args = args
        self.worktreeRoot = worktreeRoot
    }

    /// `swift-format format [--offsets <start>:<end> …] <args…> <file>`, from the worktree root. swift-format reads the
    /// file itself, named by its full path, and finds `.swift-format` and `.swift-format-ignore` from the file's
    /// folder upward. Every range goes into the one call, each as offsets into the file as it is.
    public func format(_ job: FormatJob) async throws -> FormatAnswer {
        guard job.ranges?.isEmpty != true else { return .untouched(job) }
        let offsets = Self.offsets(of: job.ranges ?? [], in: job.text).flatMap { ["--offsets", $0] }
        let invocation = Invocation(executable, ["format"] + offsets + args + [worktreeRoot + "/" + job.path],
                                    workingDirectory: worktreeRoot, timeout: FormatAnswer.timeout)
        return try await FormatAnswer.from(invocation, given: job.text, on: runner)
    }

    /// Each range as `--offsets` takes it, which every swift-format does: `--lines` came with 6.4, so the one in
    /// Xcode 26 refuses it. These are the offsets 6.4 works out for its own `--lines`: from the first
    /// byte of the first line to the byte before the line after the last, or before the end of the text when there
    /// is no such line. They count the bytes of `text`, which has no byte order mark, as the text swift-format reads
    /// has none. Its lines end in `\n` only: a file with a carriage return is never handed over by ranges.
    static func offsets(of ranges: [LineRange], in text: String) -> [String] {
        var starts = [0]
        for (offset, byte) in text.utf8.enumerated() where byte == UInt8(ascii: "\n") { starts.append(offset + 1) }
        func start(ofLine line: Int) -> Int { line <= starts.count ? starts[max(line, 1) - 1] : text.utf8.count }
        return ranges.map { range in
            let first = start(ofLine: range.first), next = start(ofLine: range.last + 1)
            return first == next ? "\(first):\(first)" : "\(first):\(next - 1)"
        }
    }
}
