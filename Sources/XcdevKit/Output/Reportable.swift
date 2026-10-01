/// A command result. `text` is the compact, agent-oriented rendering (no trailing newline);
/// the Encodable form is the `data` field of the JSON envelope.
public protocol Reportable: Encodable, Sendable {
    var text: String { get }
    /// Worktree name for the JSON envelope's `worktree` field.
    var envelopeWorktree: String? { get }
}

public extension Reportable {
    var envelopeWorktree: String? { nil }
}

public enum OutputFormat: String, Sendable {
    case text, json

    public static func resolve(jsonFlag: Bool, environment: [String: String]) -> OutputFormat {
        if jsonFlag { return .json }
        return environment["XCD_OUTPUT"]?.lowercased() == "json" ? .json : .text
    }
}
