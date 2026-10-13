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

    /// `swift-format format [--lines <first>:<last> …] <args…> <file>`, from the worktree root. swift-format reads the
    /// file itself, named by its full path, and finds `.swift-format` and `.swift-format-ignore` from the file's
    /// folder upward. Every range goes into the one call, each naming lines of the file as it is.
    public func format(_ job: FormatJob) async throws -> FormatAnswer {
        guard job.ranges?.isEmpty != true else { return .untouched(job) }
        let lines = (job.ranges ?? []).flatMap { ["--lines", "\($0.first):\($0.last)"] }
        let invocation = Invocation(executable, ["format"] + lines + args + [worktreeRoot + "/" + job.path],
                                    workingDirectory: worktreeRoot, timeout: FormatAnswer.timeout)
        return try await FormatAnswer.from(invocation, given: job.text, on: runner)
    }
}
