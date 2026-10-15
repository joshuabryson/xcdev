/// Questions to git that have a one-line answer, asked in one directory. git answers "no" to each of them with exit 1
/// and nothing on stderr. Any other failure is git's, and is thrown as `git_failed`.
struct GitQuery: Sendable {
    let runner: any ProcessRunning
    let directory: String

    /// git's output without the newline at its end, or nil when git answered "no" or printed nothing.
    func line(_ arguments: [String]) async throws -> String? {
        let invocation = Invocation.git(arguments, in: directory)
        let output = try await runner.run(invocation)
        if output.exitCode == 1, output.stderr.isEmpty { return nil }
        guard output.succeeded else { throw XcdError.subprocess(invocation, output) }
        let line = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    /// The commit `ref` names, or nil when git does not know the ref.
    func commit(_ ref: String) async throws -> String? {
        try await line(["rev-parse", "--verify", "--quiet", ref + "^{commit}"])
    }

    /// The ref's own name: `refs/heads/main` for `main` (and for `HEAD` on that branch), `refs/remotes/origin/main`,
    /// `refs/tags/v1`. Nil for a ref that has none, such as `HEAD~2` or part of a hash, and for one git does not know.
    func fullName(_ ref: String) async throws -> String? {
        try await line(["rev-parse", "--symbolic-full-name", "--verify", "--quiet", ref])
    }

    /// Whether the repository is a shallow clone, whose history stops short of its first commit.
    func isShallow() async throws -> Bool {
        try await line(["rev-parse", "--is-shallow-repository"]) == "true"
    }
}
