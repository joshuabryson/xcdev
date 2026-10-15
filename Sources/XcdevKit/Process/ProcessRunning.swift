public protocol ProcessRunning: Sendable {
    /// Runs to completion. A non-zero exit is returned, not thrown.
    /// Throws `.timeout` when the invocation's timeout elapses (or, with `stopAtTimeout`, returns with
    /// `stoppedAtDeadline` set), and `.subprocessFailed` if it cannot launch.
    func run(_ invocation: Invocation) async throws -> ProcessOutput
}

public extension ProcessRunning {
    @discardableResult
    func runChecked(_ invocation: Invocation, code: ErrorCode = .subprocessFailed,
                    message: String? = nil, next: String? = nil) async throws -> ProcessOutput {
        let output = try await run(invocation)
        guard output.succeeded else {
            throw XcdError.subprocess(invocation, output, code: code, message: message, next: next)
        }
        return output
    }
}

extension XcdError {
    public static func subprocess(_ invocation: Invocation, _ output: ProcessOutput,
                                  code: ErrorCode = .subprocessFailed, message: String? = nil,
                                  next: String? = nil) -> XcdError {
        if code == .subprocessFailed, GitFailure.isGit(invocation) {
            return GitFailure.error(invocation, output, message: message, next: next)
        }
        let tail = output.stderrString
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(20)
            .map(String.init)
        let summary = invocation.argv.prefix(3).joined(separator: " ")
        return XcdError(code, message ?? "`\(summary)` failed (exit \(output.exitCode))", next: next,
                        details: ["command: \(invocation.commandLine)", "exit: \(output.exitCode)"] + tail)
    }
}
