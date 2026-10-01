import Foundation

public enum Renderer {
    /// A command's result. A payload with a `failure` renders as `ok: false` with both `data` and `error`;
    /// in text, the failure's `next` is appended so every failed task ends with `next:`.
    public static func report<P: Reportable>(_ payload: P, command: String, format: OutputFormat) -> String {
        switch format {
        case .text:
            guard let next = payload.failure?.next else { return payload.text }
            return payload.text + "\nnext: \(next)"
        case .json:
            return encode(Envelope(ok: payload.failure == nil, command: command, worktree: payload.envelopeWorktree,
                                   data: payload, error: payload.failure.map(ErrorBody.init)))
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
            return encode(Envelope<Empty>(ok: false, command: command, worktree: worktree,
                                          data: nil, error: ErrorBody(error)))
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

    init(_ error: XcdError) {
        code = error.code.rawValue
        message = error.message
        next = error.next
        details = error.details.isEmpty ? nil : error.details
    }
}

private struct Empty: Encodable {}
