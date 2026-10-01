public struct LogsReport: Reportable {
    public enum Source: String, Codable, Sendable {
        case unifiedLog = "unified_log"
        case appOutput = "app_output"
    }

    public let source: Source
    public let entries: [LogEntry]
    public let lines: [String]
    /// Matches before `--limit` was applied.
    public let total: Int
    public let processName: String
    public let target: String
    /// "last 2m00s", "followed 30.0s", or "latest launch".
    public let window: String
    /// The app log (for --app) or the captured stream (for --follow).
    public let file: String?
    public let worktree: String

    public var text: String {
        let shown = source == .appOutput ? lines.count : entries.count
        let noun = source == .appOutput
            ? "line\(shown == 1 ? "" : "s") of app output"
            : "log entr\(shown == 1 ? "y" : "ies")"
        var header = shown == 0 && source == .unifiedLog ? "no log entries" : "\(shown) \(noun)"
        header += "  process=\(processName) device=\(target) \(window)"
        if total > shown {
            header += "  (showing the last \(shown) of \(total); narrow with --grep or --since, or raise --limit)"
        }
        var out = [header]
        if source == .appOutput, let file { out.append("file: \(file)") }
        out += source == .appOutput ? lines : entries.map(\.text)
        if source == .unifiedLog && entries.isEmpty {
            out.append("hint: Logger .debug messages need --level debug; Apple framework messages need --system")
        }
        return out.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktree }
}
