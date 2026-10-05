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
            self.accept(connection)
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

    /// Seconds a connection has to send a whole request before it is closed.
    private static let requestDeadline = 10.0

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.requestDeadline, execute: deadline)
        read(connection, Data(), deadline)
    }

    private func read(_ connection: NWConnection, _ soFar: Data, _ deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = soFar
            if let data { buffer.append(data) }
            switch HTTPRequestParser.parse(buffer) {
            case .request(let request):
                deadline.cancel()
                self.dispatch(request, connection)
            case .malformed:
                deadline.cancel()
                Self.send(400, Data(#"{"ok":false}"#.utf8), on: connection)
            case .tooLarge:
                deadline.cancel()
                Self.send(413, Data(#"{"ok":false}"#.utf8), on: connection)
            case .needMore:
                if done || error != nil {
                    deadline.cancel()
                    connection.cancel()
                } else {
                    self.read(connection, buffer, deadline)
                }
            }
        }
    }

    private static func send(_ status: Int, _ data: Data, on connection: NWConnection) {
        let reason = status == 200 ? "OK" : "Error"
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(data)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func dispatch(_ request: HTTPRequest, _ connection: NWConnection) {
        let reply: (Int, Data) -> Void = { status, data in Self.send(status, data, on: connection) }
        // Authentication fails closed: with no token set, nothing is answered.
        guard let token, !token.isEmpty, request.headers["authorization"] == "Bearer \(token)" else {
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
}
