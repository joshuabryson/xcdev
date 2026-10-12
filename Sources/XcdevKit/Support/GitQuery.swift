/// Questions to git that have a one-line answer, asked in one directory. A command that fails has no answer.
struct GitQuery: Sendable {
    let runner: any ProcessRunning
    let directory: String

    /// git's output without the newline at its end, or nil when git failed or printed nothing.
    func line(_ arguments: [String]) async -> String? {
        guard let output = try? await runner.run(.git(arguments, in: directory)), output.succeeded else { return nil }
        let line = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    /// The commit `ref` names, or nil when git does not know the ref.
    func commit(_ ref: String) async -> String? {
        await line(["rev-parse", "--verify", "--quiet", ref + "^{commit}"])
    }

    /// The ref's own name: `refs/heads/main` for `main` (and for `HEAD` on that branch), `refs/remotes/origin/main`,
    /// `refs/tags/v1`. Nil for a ref that has none, such as `HEAD~2` or part of a hash, and for one git does not know.
    func fullName(_ ref: String) async -> String? {
        await line(["rev-parse", "--symbolic-full-name", "--verify", "--quiet", ref])
    }
}
