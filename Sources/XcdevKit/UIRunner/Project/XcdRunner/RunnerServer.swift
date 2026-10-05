import Foundation
import Network

struct RunnerJob {
    let path: String
    let body: Data
    let reply: (Int, Data) -> Void
}

/// A minimal HTTP/1.1 server on 127.0.0.1. `/health` and rejections are answered on the listener's queue; every other
/// request is queued for the main thread, one at a time (a second request while one runs gets 409).
final class RunnerServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.xcdev.runner.listener")
    private var listener: NWListener?
    private let lock = NSLock()
    private var pending: RunnerJob?
    private var busy = false
    private let token: String?
    /// Answers `/health` without touching XCUITest.
    private let health: () -> Data

    init(token: String?, health: @escaping () -> Data) {
        self.token = token
        self.health = health
    }

    /// Starts listening and returns the port the system chose.
    func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.read(connection, Data())
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 10)
        guard let port = listener.port?.rawValue, port != 0 else {
            throw NSError(domain: "dev.xcdev.runner", code: 1, userInfo: [NSLocalizedDescriptionKey: "the listener did not start: \(listener.state)"])
        }
        return port
    }

    /// The request waiting for the main thread, if any.
    func next() -> RunnerJob? {
        lock.lock()
        defer { lock.unlock() }
        let job = pending
        pending = nil
        return job
    }

    /// Called on the main thread when a job's reply has been sent.
    func finished() {
        lock.lock()
        busy = false
        lock.unlock()
    }

    private func read(_ connection: NWConnection, _ soFar: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = soFar
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.dispatch(request, connection)
                return
            }
            if done || error != nil {
                connection.cancel()
                return
            }
            self.read(connection, buffer)
        }
    }

    private func dispatch(_ request: (path: String, headers: [String: String], body: Data), _ connection: NWConnection) {
        let reply: (Int, Data) -> Void = { status, data in
            let reason = status == 200 ? "OK" : "Error"
            var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(data)
            connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
        }
        if let token, request.headers["authorization"] != "Bearer \(token)" {
            reply(401, Data(#"{"ok":false}"#.utf8))
            return
        }
        if request.path == "/health" {
            reply(200, health())
            return
        }
        lock.lock()
        let accepted = !busy
        if accepted {
            busy = true
            pending = RunnerJob(path: request.path, body: request.body, reply: reply)
        }
        lock.unlock()
        guard accepted else {
            reply(409, Data(#"{"ok":false}"#.utf8))
            return
        }
        // Wake the main run loop so the test method picks the job up.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(CFRunLoopGetMain()) }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    static func parse(_ buffer: Data) -> (path: String, headers: [String: String], body: Data)? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        guard let requestLine = head.first else { return nil }
        let first = requestLine.split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[separator.upperBound...]
        guard body.count >= length else { return nil }
        return (String(first[1]), headers, Data(body.prefix(length)))
    }
}
