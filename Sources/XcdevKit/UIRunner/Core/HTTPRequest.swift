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
/// for more than the limits below.
public enum HTTPRequestParser {
    public static let maxHeaderBytes = 64 * 1024
    public static let maxBodyBytes = 1024 * 1024

    public static func parse(_ buffer: Data) -> HTTPParse {
        let terminator = Data("\r\n\r\n".utf8)
        guard let separator = buffer.range(of: terminator) else {
            return buffer.count > maxHeaderBytes ? .tooLarge : .needMore
        }
        if separator.lowerBound > maxHeaderBytes { return .tooLarge }
        let head = String(decoding: buffer[buffer.startIndex..<separator.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = (head.first ?? "").split(separator: " ")
        guard requestLine.count >= 2 else { return .malformed("the request line has no method and path") }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var length = 0
        if let declared = headers["content-length"] {
            guard !declared.isEmpty, declared.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
                return .malformed("Content-Length is not a non-negative integer")
            }
            // Digits that overflow an Int are certainly too large.
            guard let parsed = Int(declared), parsed <= maxBodyBytes else { return .tooLarge }
            length = parsed
        }
        let body = buffer[separator.upperBound...]
        guard body.count >= length else { return .needMore }
        return .request(HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers,
                                    body: Data(body.prefix(length))))
    }
}
