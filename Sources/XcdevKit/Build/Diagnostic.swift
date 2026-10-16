import Foundation

/// A compiler or test diagnostic, passed through unchanged apart from formatting.
public struct Diagnostic: Codable, Sendable, Equatable {
    public enum Severity: String, Codable, Sendable { case error, warning }

    public let severity: Severity
    public let message: String
    public let file: String?
    public let line: Int?
    public let column: Int?
    /// True for a warning xcd kept from an earlier build of a file this build did not compile.
    public var earlier: Bool?

    public init(_ severity: Severity, _ message: String, file: String? = nil, line: Int? = nil, column: Int? = nil) {
        self.severity = severity
        self.message = message
        self.file = file
        self.line = line
        self.column = column
    }

    /// Compiler format, `path:line:col: error: message`. Extra message lines are indented under it.
    public var text: String {
        var location = ""
        if let file {
            location = file
            if let line {
                location += ":\(line)"
                if let column { location += ":\(column)" }
            }
            location += ": "
        }
        return location + "\(severity.rawValue): " + message.replacingOccurrences(of: "\n", with: "\n    ")
    }
}
