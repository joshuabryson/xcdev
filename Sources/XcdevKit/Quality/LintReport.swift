/// How much of the project a quality command covers.
public enum QualityScope: String, Codable, Sendable {
    /// What the change introduced: the default.
    case lines
    /// The changed files, whole.
    case files
    /// Every Swift file git knows.
    case all
}

/// The result of `xcd lint`.
public struct LintReport: Reportable {
    /// What `tool` says for `lint.tool: none`.
    public static let noTool = QualityHeadline.noTool
    static let rerun = "run `xcd lint` again"

    /// What ran: `swiftlint`, the first line of the project's own command, or `none`.
    public let tool: String
    public let scope: QualityScope
    /// The ref the change is measured against, and the commit where the work left it. Absent with `--all`.
    public let base: String?
    public let baseCommit: String?
    /// How many Swift files were in scope.
    public let files: Int
    /// The findings shown: the ones the change introduced in the default scope, all of them otherwise.
    public var findings: [LintFinding] = []
    /// In the default scope, how many findings the files already had.
    public var older = 0
    public var notes: [String] = []
    /// The tool's raw output.
    public var log: String?
    public var seconds = 0.0
    /// For a project's own command: what it printed, and how it exited.
    public var output: String?
    public var exitCode: Int32?
    public let worktree: String

    public init(tool: String, scope: QualityScope, base: String?, baseCommit: String?, files: Int, worktree: String) {
        self.tool = tool
        self.scope = scope
        self.base = base
        self.baseCommit = baseCommit
        self.files = files
        self.worktree = worktree
    }

    public var envelopeWorktree: String? { worktree }

    public var text: String {
        var lines = [headline] + notes.map { "note: " + $0 }
        if let log, !notes.isEmpty { lines.append("log: \(log)") }
        lines += findings.map(\.text)
        if let output = output?.trimmingCharacters(in: .newlines), !output.isEmpty { lines.append(output) }
        if older > 0 { lines.append("\(Self.count(older, "older finding")) in these files (xcd lint --files)") }
        return lines.joined(separator: "\n")
    }

    /// `lint: 2 new findings  tool=swiftlint  files=3  base=main  1.8s`. With nothing linted, only what and why.
    var headline: String {
        QualityHeadline(command: "lint", tool: tool, files: files, base: base, seconds: seconds).text(summary)
    }

    var summary: String {
        if tool == Self.noTool { return "no linter is set up" }
        if files == 0 { return nothingInScope ?? "no Swift files in scope" }
        if let exitCode { return exitCode == 0 ? "passed" : "failed" }
        let kind = scope == .lines ? "new finding" : "finding"
        return findings.isEmpty ? "no \(kind)s" : Self.count(findings.count, kind)
    }

    /// Why nothing was linted, for the first line. Not part of the JSON.
    private var nothingInScope: String?

    enum CodingKeys: String, CodingKey {
        case tool, scope, base, baseCommit, files, findings, older, notes, log, seconds, output, exitCode, worktree
    }

    /// `lint_failed` when a shown finding is an error as the tool reports it, or the project's command exited
    /// non-zero. Warnings are listed and the command succeeds.
    public var failure: XcdError? {
        if let exitCode, exitCode != 0 {
            return XcdError(.lintFailed, "the project's lint command exited \(exitCode)", next: "fix what it reports and \(Self.rerun)")
        }
        let errors = findings.filter { $0.severity == .error }.count
        guard errors > 0 else { return nil }
        let subject = findings.count == 1 ? "the finding" : "\(errors) of the \(findings.count) findings"
        return XcdError(.lintFailed, "\(subject) \(errors == 1 ? "is an error" : "are errors")", next: "fix the findings and \(Self.rerun)")
    }

    static func count(_ number: Int, _ noun: String) -> String {
        QualityHeadline.count(number, noun)
    }
}

extension LintReport {
    /// This result, worded for no Swift file in scope. `paths` are the ones given, relative to the worktree root.
    public func nothingInScope(under paths: [String]) -> LintReport {
        var report = self
        let wording = scope.nothingInScope(since: base, under: paths)
        report.nothingInScope = wording.summary
        if wording.changeHeldNone { report.notes = ["`xcd lint --all` lints the whole project"] }
        return report
    }

    /// The result for `lint.tool: none`. With a SwiftLint config in the project, a note says which line turns it on.
    public static func off(scope: QualityScope, hasConfigFile: Bool, worktree: String) -> LintReport {
        var report = LintReport(tool: noTool, scope: scope, base: nil, baseCommit: nil, files: 0, worktree: worktree)
        if hasConfigFile {
            report.notes = ["\(SwiftLintConfig.fileName) found: set `lint.tool: swiftlint` in .xcdev.yml to have `xcd lint` use it"]
        }
        return report
    }

    /// A tool's stderr as notes: three lines at most, then how many more the log holds.
    public static func toolNotes(_ lines: [String], from tool: String) -> [String] {
        let more = lines.count - 3
        let rest = more == 1 ? "1 more line is in the log" : "\(more) more lines are in the log"
        return (lines.prefix(3) + (more > 0 ? [rest] : [])).map { "\(tool): \($0)" }
    }
}
