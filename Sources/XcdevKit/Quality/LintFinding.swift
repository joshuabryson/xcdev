/// One thing a linter reported about a file.
public struct LintFinding: Codable, Sendable, Equatable {
    /// Relative to the worktree root.
    public let file: String
    /// Nil for a finding about the file as a whole.
    public let line: Int?
    public let column: Int?
    /// As the tool reports it.
    public let severity: Diagnostic.Severity
    /// The rule's identifier, such as `line_length`.
    public let rule: String
    /// The tool's own words.
    public let message: String

    public init(file: String, line: Int?, column: Int?, severity: Diagnostic.Severity, rule: String, message: String) {
        self.file = file
        self.line = line
        self.column = column
        self.severity = severity
        self.rule = rule
        self.message = message
    }

    /// Compiler format, with the rule after the message: `path:line:col: warning: message (rule)`.
    public var text: String {
        Diagnostic(severity, "\(message) (\(rule))", file: file, line: line, column: column).text
    }
}

/// One version of a file: its text, and what the linter found in it.
public struct FileFindings: Sendable, Equatable {
    public let text: String
    public let findings: [LintFinding]

    public init(text: String, findings: [LintFinding]) {
        self.text = text
        self.findings = findings
    }
}
