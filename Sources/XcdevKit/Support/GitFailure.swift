import Foundation

/// A git command that failed, rather than answering "no": reported as `git_failed`
/// with git's own lines, and with what to do for the causes whose git wording is known. `/usr/bin/git`
/// has no translations, so its words are always these.
enum GitFailure {
    static let next = "fix what git says above, then run the command again"

    static func isGit(_ invocation: Invocation) -> Bool { invocation.argv.first == "git" }

    /// The error for `invocation`, which exited non-zero. A cause git names takes the place of the caller's own
    /// `message` and `next`.
    static func error(_ invocation: Invocation, _ output: ProcessOutput, message: String?, next: String?) -> XcdError {
        let lines = output.stderrString.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var error = XcdError(.gitFailed, message ?? said(lines.first, invocation, output), next: next ?? Self.next,
                             details: ["command: \(invocation.commandLine)", "exit: \(output.exitCode)"] + lines.suffix(20))
        if let cause = cause(lines) {
            error.message = cause.message ?? error.message
            error.next = cause.next
        }
        return error
    }

    /// git's first line without its `fatal: ` or `error: `, or the command and its exit code when git said nothing.
    static func said(_ first: String?, _ invocation: Invocation, _ output: ProcessOutput) -> String {
        guard let first else { return "`\(words(of: invocation).joined(separator: " "))` failed (exit \(output.exitCode))" }
        for prefix in ["fatal: ", "error: "] where first.hasPrefix(prefix) {
            return "git failed: " + first.dropFirst(prefix.count)
        }
        return "git failed: " + first
    }

    /// `git` and the words after it that name the command, without a leading `-C <dir>`.
    static func words(of invocation: Invocation) -> [String] {
        var argv = invocation.argv
        if argv.count > 2, argv[1] == "-C" { argv.removeSubrange(1...2) }
        return Array(argv.prefix(3))
    }

    struct Cause {
        /// Nil keeps git's own words.
        let message: String?
        let next: String
    }

    static func cause(_ lines: [String]) -> Cause? {
        if let owner = lines.first(where: { $0.contains("detected dubious ownership in repository at '") }) {
            return Cause(message: "git refuses this repository because another user owns it",
                         next: "ask the user whether to trust it; git's own fix is `\(trustCommand(lines, owner))`")
        }
        if let lock = lines.lazy.compactMap(lockFile).first {
            return Cause(message: nil, next: "another git command is using this repository, maybe another agent's: "
                             + "wait a moment and run the command again; ask the user before deleting \(lock)")
        }
        return nil
    }

    /// The command git printed to trust the repository, or one made from the path it named.
    static func trustCommand(_ lines: [String], _ owner: String) -> String {
        let command = "git config --global --add safe.directory"
        if let printed = lines.lazy.map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix(command + " ") }) {
            return printed
        }
        let path = owner.components(separatedBy: "repository at '").last.map { String($0.dropLast()) } ?? ""
        return command + " " + Shell.quote(path)
    }

    /// The lock file in git's `Unable to create '<path>.lock': File exists.`
    static func lockFile(_ line: String) -> String? {
        guard let start = line.range(of: "Unable to create '"), let end = line.range(of: ".lock': File exists", range: start.upperBound..<line.endIndex)
        else { return nil }
        return String(line[start.upperBound..<end.lowerBound]) + ".lock"
    }
}
