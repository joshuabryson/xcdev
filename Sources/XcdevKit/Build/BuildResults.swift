import Foundation

/// `xcrun xcresulttool get build-results --path <bundle>`.
public struct BuildResults: Sendable, Equatable {
    public let succeeded: Bool
    public let errors: [Diagnostic]
    public let warnings: [Diagnostic]
    public let warningCount: Int

    public static func parse(_ data: Data) throws -> BuildResults {
        struct Issue: Decodable { let message: String; let sourceURL: String? }
        struct Raw: Decodable {
            let status: String?
            let warningCount: Int?
            let errors: [Issue]?
            let warnings: [Issue]?
        }
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch {
            throw XcdError(.subprocessFailed, "could not parse `xcresulttool get build-results` output", details: ["\(error)"])
        }
        func diagnostics(_ issues: [Issue]?, _ severity: Diagnostic.Severity) -> [Diagnostic] {
            (issues ?? []).map { issue in
                let location = issue.sourceURL.flatMap(location(fromSourceURL:))
                return Diagnostic(severity, issue.message, file: location?.file, line: location?.line, column: location?.column)
            }
        }
        let warnings = diagnostics(raw.warnings, .warning)
        return BuildResults(succeeded: raw.status == "succeeded", errors: diagnostics(raw.errors, .error),
                            warnings: warnings, warningCount: raw.warningCount ?? warnings.count)
    }

    /// `file:///a%20b/X.swift#StartingLineNumber=2&StartingColumnNumber=15&…` → ("/a b/X.swift", 3, 16).
    /// xcresulttool's line and column numbers are 0-based; compilers print 1-based.
    public static func location(fromSourceURL sourceURL: String) -> (file: String, line: Int?, column: Int?)? {
        guard let url = URL(string: sourceURL), url.isFileURL else { return nil }
        var fields: [String: Int] = [:]
        for pair in (url.fragment ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, let value = Int(parts[1]) { fields[String(parts[0])] = value }
        }
        return (url.path, fields["StartingLineNumber"].map { $0 + 1 }, fields["StartingColumnNumber"].map { $0 + 1 })
    }
}
