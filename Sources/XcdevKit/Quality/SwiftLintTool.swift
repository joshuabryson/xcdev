import Foundation

/// What one SwiftLint run gave.
public struct SwiftLintRun: Sendable, Equatable {
    /// Findings whose `file` is relative to the folder SwiftLint ran in.
    public let findings: [LintFinding]
    /// What SwiftLint wrote to stderr, line by line: a config it could not read, a rule it does not know.
    public let notes: [String]
    /// The command, its exit code, and its raw output, for the log.
    public let transcript: String
}

/// Runs SwiftLint in a scratch folder and reads its findings.
public struct SwiftLintTool: Sendable {
    /// What xcd passes itself. The JSON reporter gives findings xcd can read; no cache is kept between runs.
    public static let ownArguments = ["lint", "--quiet", "--reporter", "json", "--no-cache"]
    public static let timeout: Duration = .seconds(600)
    /// What SwiftLint says when the config leaves out every file in the folder.
    static let nothingToLint = "No lintable files found"

    public let runner: any ProcessRunning
    public let executable: String
    /// The project's `lint.args`, placed after xcd's own.
    public let args: [String]

    public init(runner: any ProcessRunning, executable: String, args: [String]) {
        self.runner = runner
        self.executable = executable
        self.args = args
    }

    /// Lints `folder` with no paths, so SwiftLint picks among the folder's files by the config's own `included`
    /// and `excluded` lists. A list of findings on stdout is the result whatever the exit code, which differs
    /// between SwiftLint versions. A finding for a file outside the folder means SwiftLint did not lint what xcd gave it,
    /// so that is a failure too. Anything else but "nothing to lint" is a tool that failed, never findings.
    public func lint(_ folder: LintFolder) async throws -> SwiftLintRun {
        let invocation = Invocation(executable, Self.ownArguments + args, workingDirectory: folder.root, timeout: Self.timeout)
        let output = try await runner.run(invocation)
        let transcript = "$ \(invocation.commandLine)\nexit \(output.exitCode)\n\(output.stderrString)\(output.stdoutString)"
        if let reported = try? JSONDecoder().decode([Reported].self, from: output.stdout) {
            if let stray = reported.compactMap(\.file).first(where: { folder.path(of: $0) == nil }) {
                throw XcdError.subprocess(invocation, output, message: "swiftlint linted a file outside the folder xcd gave it: \(stray)",
                                          next: "the lint config leads SwiftLint out of the copy xcd made: look for an absolute path or an environment variable in its included, parent_config, or child_config, and use a path relative to the worktree")
            }
            let notes = output.stderrString.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return SwiftLintRun(findings: reported.compactMap { $0.finding(in: folder) }, notes: notes, transcript: transcript)
        }
        if !output.succeeded, output.stderrString.contains(Self.nothingToLint) {
            return SwiftLintRun(findings: [], notes: [], transcript: transcript)
        }
        throw XcdError.subprocess(invocation, output, message: "swiftlint gave no result xcd can read (exit \(output.exitCode))",
                                  next: "run `swiftlint lint` in the project to see what it says, and check lint.args in .xcdev.yml")
    }

    /// One entry of SwiftLint's JSON reporter.
    struct Reported: Decodable {
        let file: String?
        let line: Int?
        let character: Int?
        let severity: String
        let ruleID: String
        let reason: String

        enum CodingKeys: String, CodingKey {
            case file, line, character, severity, reason
            case ruleID = "rule_id"
        }

        /// Nil for an entry that names no file. `lint` has already refused an entry whose file is outside the folder.
        func finding(in folder: LintFolder) -> LintFinding? {
            guard let path = file.flatMap(folder.path(of:)) else { return nil }
            return LintFinding(file: path, line: line, column: character, severity: severity.lowercased() == "error" ? .error : .warning,
                               rule: ruleID, message: reason)
        }
    }
}
