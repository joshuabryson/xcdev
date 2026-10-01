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
