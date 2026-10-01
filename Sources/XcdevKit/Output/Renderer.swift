import Foundation

public enum Renderer {
    public static func success<P: Reportable>(_ payload: P, command: String, format: OutputFormat) -> String {
        switch format {
        case .text:
            return payload.text
        case .json:
            return encode(Envelope(ok: true, command: command, worktree: payload.envelopeWorktree,
                                   data: payload, error: nil))
        }
    }

    public static func failure(_ error: XcdError, command: String, worktree: String? = nil,
                               format: OutputFormat) -> String {
        switch format {
        case .text:
            var lines = ["error[\(error.code.rawValue)]: \(error.message)"]
            lines += error.details.map { "  " + $0 }
            if let next = error.next { lines.append("next: \(next)") }
            return lines.joined(separator: "\n")
        case .json:
            let body = ErrorBody(code: error.code.rawValue, message: error.message, next: error.next,
                                 details: error.details.isEmpty ? nil : error.details)
            return encode(Envelope<Empty>(ok: false, command: command, worktree: worktree,
                                          data: nil, error: body))
        }
    }

    /// A command-line parse error as a `usage` failure. The first line of `message` (minus ArgumentParser's
    /// "Error: " prefix) is the message; later lines become details. `arguments` excludes argv[0].
    public static func usageFailure(message: String, arguments: [String], environment: [String: String]) -> String {
        var lines = message.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var first = lines.isEmpty ? "invalid command line" : lines.removeFirst()
        if first.hasPrefix("Error: ") { first.removeFirst("Error: ".count) }
        let error = XcdError(.usage, first, next: "run `xcd help` or `xcd <command> --help`", details: lines)
        let format = OutputFormat.resolve(jsonFlag: arguments.contains("--json"), environment: environment)
        let command = arguments.filter { !$0.hasPrefix("-") }.joined(separator: " ")
        return failure(error, command: command, format: format)
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        let data = (try? JSONCoding.encoder(pretty: false).encode(value)) ?? Data(#"{"ok":false}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

private struct Envelope<Payload: Encodable>: Encodable {
    let ok: Bool
    let command: String
    let worktree: String?
    let data: Payload?
    let error: ErrorBody?
}

private struct ErrorBody: Encodable {
    let code: String
    let message: String
    let next: String?
    let details: [String]?
}

private struct Empty: Encodable {}
