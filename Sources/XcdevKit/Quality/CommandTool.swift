import Foundation

/// Runs a project's own command for a quality section, such as `lint.run`.
public struct CommandTool: Sendable {
    public static let timeout: Duration = .seconds(600)
    /// The longest file list handed to a command, in bytes. A command line holds about a megabyte, and the
    /// environment takes its share of that.
    public static let longestFileList = 250_000

    public struct Result: Sendable, Equatable {
        public let exitCode: Int32
        /// What the command printed, stdout and stderr in the order they came.
        public let output: String
        public let log: String
    }

    public let runner: any ProcessRunning
    /// Passed to the command as XCD_OUTPUT.
    public let output: OutputFormat
    public let timeout: Duration
    public let now: @Sendable () -> Date

    public init(runner: any ProcessRunning, output: OutputFormat = .text, timeout: Duration = CommandTool.timeout,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.output = output
        self.timeout = timeout
        self.now = now
    }

    /// Runs `/bin/sh -c '<command> "$@"' xcd-<section> <files…>` from the worktree root with the worktree's context
    /// variables, the way a project command gets its arguments, so a path with a space stays one argument. The
    /// command runs once. Its exit code is returned, not thrown, except 126 and 127: those are the shell saying it
    /// could not run the command, which is not a result. `section` is the config section, `lint`.
    public func run(_ command: String, section: String, files: [String], in ctx: WorktreeContext) async throws -> Result {
        guard files.reduce(0, { $0 + $1.utf8.count + 1 }) <= Self.longestFileList else {
            throw XcdError(.usage, "\(files.count) files are too many to hand to \(section).run on one command line",
                           next: "pass --all with no paths so the command covers the project its own way, or name fewer paths")
        }
        let command = Self.withoutItsEnd(command)
        let log = ctx.paths.newArtifact(in: ctx.paths.logs, kind: section, ext: "log", now: now())
        let context = ContextInfo.build(ctx: ctx, device: nil, output: output)
        let invocation = Invocation("/bin/sh", ["-c", command + " \"$@\"", "xcd-" + section] + files, environment: context.environment,
                                    workingDirectory: ctx.location.worktreeRoot, timeout: timeout, outputFile: log)
        let exitCode: Int32
        do {
            exitCode = try await runner.run(invocation).exitCode
        } catch let error as XcdError where error.code == .timeout {
            throw timedOut(error, command: command, section: section, log: log)
        }
        let printed = Self.text(of: log)
        if let next = Self.notRun(exitCode, section: section) {
            throw XcdError(.subprocessFailed, "the project's \(section) command could not be run (exit \(exitCode))", next: next,
                           details: ["command: \(command)", "log: \(log)"] + printed.split(separator: "\n").suffix(20).map(String.init))
        }
        return Result(exitCode: exitCode, output: printed, log: log)
    }

    /// The command without the whitespace, newlines and `;` at its end, so the files land on its last line as that
    /// line's arguments. After a newline or a `;` they would be a command of their own, whose exit code would be the
    /// result. A `;` that a backslash escapes is an argument of the command, as in `find … -exec … \;`, and stays.
    static func withoutItsEnd(_ command: String) -> String {
        var kept = Substring(command)
        while let last = kept.last, last.isWhitespace || last == ";" {
            let escaped = kept.dropLast().reversed().prefix { $0 == "\\" }.count % 2 == 1
            if last == ";" && escaped { break }
            kept.removeLast()
        }
        return String(kept)
    }

    /// The runner's timeout error, with this command's message and next step, and the command and the log as its details
    /// instead of the whole argument list.
    private func timedOut(_ error: XcdError, command: String, section: String, log: String) -> XcdError {
        var error = error
        error.message = "the project's \(section) command timed out after \(DurationText.format(timeout))"
        error.next = "make \(section).run finish sooner, or name paths to give it fewer files"
        error.details = ["command: \(command)", "log: \(log)"]
        return error
    }

    /// What the command printed, decoded leniently so a byte that is not UTF-8 does not hide the rest. A log that cannot
    /// be read is empty.
    private static func text(of log: String) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: log)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// What to do about the shell's "not found" (127) and "not executable" (126). Nil for any other exit code.
    static func notRun(_ exitCode: Int32, section: String) -> String? {
        switch exitCode {
        case 127: return "its command was not found; check \(section).run in .xcdev.yml (paths are relative to the worktree root)"
        case 126: return "its script is not executable; run `chmod +x` on it"
        default: return nil
        }
    }
}
