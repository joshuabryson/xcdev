import Foundation
import Testing
@testable import XcdevKit

@Suite struct HTTPRequestTests {
    func parse(_ text: String) -> HTTPParse { HTTPRequestParser.parse(Data(text.utf8)) }

    @Test func aGetWithNoBody() {
        let result = parse("GET /health HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer t\r\n\r\n")
        #expect(result == .request(HTTPRequest(method: "GET", path: "/health",
                                               headers: ["host": "x", "authorization": "Bearer t"], body: Data())))
    }

    @Test func aPostSplitAcrossTwoBuffers() {
        let head = "POST /tap HTTP/1.1\r\nContent-Length: 7\r\n\r\n{\"a\""
        #expect(parse(head) == .needMore)
        guard case .request(let request) = parse(head + "):1") else { Issue.record("expected a request"); return }
        #expect(request.method == "POST" && request.path == "/tap")
        #expect(request.body == Data("{\"a\"):1".utf8))
    }

    @Test func badContentLengthIsMalformed() {
        for value in ["-1", "abc", "", "1.5"] {
            guard case .malformed = parse("POST /x HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n") else {
                Issue.record("Content-Length '\(value)' was not malformed"); continue
            }
        }
    }

    @Test func aRequestLineWithoutAPathIsMalformed() {
        guard case .malformed = parse("GET\r\n\r\n") else { Issue.record("expected malformed"); return }
    }

    @Test func limits() {
        #expect(parse("POST /x HTTP/1.1\r\nContent-Length: 2097152\r\n\r\n") == .tooLarge)
        #expect(HTTPRequestParser.parse(Data(repeating: 0x61, count: 70 * 1024)) == .tooLarge)
        #expect(HTTPRequestParser.parse(Data()) == .needMore)
    }

    @Test func oddBytesNeverTrap() {
        var head = Data("GET /x HTTP/1.1\r\nX: ".utf8)
        head.append(contentsOf: [0xff, 0xfe, 0xc0])
        head.append(Data("\r\nno colon here\r\nA: 1\r\na: 2\r\n\r\n".utf8))
        guard case .request(let request) = HTTPRequestParser.parse(head) else { Issue.record("expected a request"); return }
        #expect(request.headers["a"] == "2")
        _ = parse("\r\n\r\n\r\n")
    }

    @Test func headerNamesAreCaseInsensitive() {
        guard case .request(let request) = parse("GET /x HTTP/1.1\r\nAUTHORIZATION: Bearer t\r\n\r\n") else {
            Issue.record("expected a request"); return
        }
        #expect(request.headers["authorization"] == "Bearer t")
    }

    @Test func extraBytesAfterTheBodyAreIgnored() {
        guard case .request(let request) = parse("POST /x HTTP/1.1\r\nContent-Length: 2\r\n\r\nabcdef") else {
            Issue.record("expected a request"); return
        }
        #expect(request.body == Data("ab".utf8))
    }

    @Test func randomBuffersNeverTrap() {
        var state: UInt64 = 0x1234_5678_9abc_def0
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        let pieces = ["\r\n", "\r\n\r\n", "Content-Length: ", "-", "9", ": ", "GET ", " ", "/", "\u{0}"]
        for _ in 0..<400 {
            var data = Data()
            for _ in 0..<Int(next() % 40) {
                if next() % 2 == 0 { data.append(UInt8(truncatingIfNeeded: next())) } else {
                    data.append(Data(pieces[Int(next() % UInt64(pieces.count))].utf8))
                }
            }
            _ = HTTPRequestParser.parse(data)
        }
    }
}
