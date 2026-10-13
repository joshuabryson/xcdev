import Foundation

/// What a formatter is asked for: one file's text, whole or by line ranges.
public struct FormatJob: Sendable, Equatable {
    /// The file, relative to the worktree root.
    public let path: String
    /// The file's text as xcd read it.
    public let text: String
    /// The ranges to format, in order, each numbered in `text`. Nil formats the whole file. No ranges at all is
    /// nothing to format, which is not the same thing.
    public let ranges: [LineRange]?

    public init(path: String, text: String, ranges: [LineRange]?) {
        self.path = path
        self.text = text
        self.ranges = ranges
    }
}

/// What a formatter gave for one file.
public struct FormatAnswer: Sendable, Equatable {
    /// How long a formatter may take over one file.
    public static let timeout: Duration = .seconds(120)

    /// The formatted text. Nil when the formatter could not process the file.
    public var text: String?
    /// What the formatter wrote to stderr, line by line: why it failed, or what it warned of while it worked.
    public var said: [String]
    /// Each run's command, its exit code, and what it wrote to stderr, for the log.
    public var transcript: String

    /// The answer of a formatter that was not run: the text as it is.
    static func untouched(_ job: FormatJob) -> FormatAnswer {
        FormatAnswer(text: job.text, said: [], transcript: "")
    }

    /// One run of a formatter that prints the formatted text. `given` is the text it was handed.
    /// - The text counts only when the formatter exits 0: SwiftFormat prints its input back when it fails.
    /// - A formatter that exits 0 and prints nothing for a file that is not empty left the file out: swift-format
    ///   does so for a file its `.swift-format-ignore` names. The text then stands as it is.
    /// - A run past its deadline is a file the formatter could not process. It does not end the command.
    /// - A formatter that cannot be started ends the command: the runner's error is thrown on, with what to do next.
    static func from(_ invocation: Invocation, given text: String, on runner: any ProcessRunning) async throws -> FormatAnswer {
        let output: ProcessOutput
        do {
            output = try await runner.run(invocation)
        } catch let error as XcdError where error.code == .timeout {
            let limit = DurationText.format(invocation.timeout)
            return FormatAnswer(text: nil, said: ["did not finish in \(limit) and was stopped"], transcript: "$ \(invocation.commandLine)\nstopped after \(limit)\n")
        } catch var error as XcdError where error.code == .subprocessFailed && error.next == nil {
            error.next = "see that \(invocation.executable) can be run, or set format.path in .xcdev.local.yml to one that can"
            throw error
        }
        let said = output.stderrString.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let transcript = "$ \(invocation.commandLine)\nexit \(output.exitCode)\n" + said.map { $0 + "\n" }.joined()
        guard output.succeeded else {
            return FormatAnswer(text: nil, said: said.isEmpty ? ["exited with code \(output.exitCode) and said nothing"] : said, transcript: transcript)
        }
        guard let formatted = String(data: output.stdout, encoding: .utf8) else {
            return FormatAnswer(text: nil, said: ["printed text that is not UTF-8"], transcript: transcript)
        }
        return FormatAnswer(text: formatted.isEmpty ? text : formatted, said: said, transcript: transcript)
    }
}

/// A formatter xcd runs on one file at a time. It gives the formatted text and writes no file
/// of the project's, so `xcd format`, `xcd format --check`, and every scope go the same way.
public protocol FormatterTool: Sendable {
    func format(_ job: FormatJob) async throws -> FormatAnswer
}
