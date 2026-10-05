import Foundation

public struct HTTPRequest: Equatable {
    public var method: String
    public var path: String
    /// Header names, lower-cased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public enum HTTPParse: Equatable {
    /// The buffer holds only part of a request.
    case needMore
    case request(HTTPRequest)
    case malformed(String)
    case tooLarge
}

/// Reads one HTTP/1.1 request from bytes a local client sent before it is trusted, so it never traps and never asks
/// for more than the limits below. A head (everything before the blank line) over `maxHeaderBytes` is `.tooLarge`
/// however the bytes were chunked: without the blank line yet, a buffer is only too large once it is more than
/// `maxHeaderBytes` plus the 3 bytes of a partly arrived terminator. `Content-Length` must be plain digits
/// (surrounding spaces allowed); anything else is `.malformed`, and a value over `maxBodyBytes` or too big for an
/// Int is `.tooLarge`.
public enum HTTPRequestParser {
    public static let maxHeaderBytes = 64 * 1024
    public static let maxBodyBytes = 1024 * 1024

    public static func parse(_ buffer: Data) -> HTTPParse {
        let terminator = Data("\r\n\r\n".utf8)
        guard let separator = buffer.range(of: terminator) else {
            return buffer.count > maxHeaderBytes + terminator.count - 1 ? .tooLarge : .needMore
        }
        if separator.lowerBound > maxHeaderBytes { return .tooLarge }
        let head = String(decoding: buffer[buffer.startIndex..<separator.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = (head.first ?? "").split(separator: " ")
        guard requestLine.count >= 2 else { return .malformed("the request line has no method and path") }
        let headers = self.headers(Array(head.dropFirst()))
        let (length, problem) = contentLength(headers["content-length"])
        if let problem { return problem }
        let body = buffer[separator.upperBound...]
        guard body.count >= length else { return .needMore }
        return .request(HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers,
                                    body: Data(body.prefix(length))))
    }

    /// Header lines as a dictionary with lower-cased names; a line with no colon is skipped, a repeated name keeps its last value.
    private static func headers(_ lines: [String]) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return headers
    }

    private static func contentLength(_ declared: String?) -> (length: Int, problem: HTTPParse?) {
        guard let declared else { return (0, nil) }
        guard !declared.isEmpty, declared.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            return (0, .malformed("Content-Length is not a non-negative integer"))
        }
        // Digits that overflow an Int are certainly too large.
        guard let parsed = Int(declared), parsed <= maxBodyBytes else { return (0, .tooLarge) }
        return (parsed, nil)
    }
}
