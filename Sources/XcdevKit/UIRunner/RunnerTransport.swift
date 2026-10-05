import Foundation

/// The runner didn't answer: nothing is listening, or the request timed out. The caller restarts the runner.
public struct RunnerUnreachable: Error, Sendable, Equatable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

public protocol RunnerTransport: Sendable {
    /// One HTTP request to the runner on 127.0.0.1. GET when `body` is nil, else POST. Throws `RunnerUnreachable`.
    func send(port: Int, token: String, path: String, body: Data?, timeout: Duration) async throws -> (status: Int, body: Data)
}

public struct URLSessionRunnerTransport: RunnerTransport {
    public init() {
        // Stateless: each request makes its own session.
    }

    public func send(port: Int, token: String, path: String, body: Data?, timeout: Duration) async throws -> (status: Int, body: Data) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw RunnerUnreachable(reason: "bad address") }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = DurationText.seconds(timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]            // loopback: never through a proxy
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            throw RunnerUnreachable(reason: error.localizedDescription)
        }
    }
}

public struct RunnerClient: Sendable {
    public let transport: any RunnerTransport

    public init(transport: any RunnerTransport) {
        self.transport = transport
    }

    /// The runner's health, or nil when it doesn't answer, rejects the token, or speaks another protocol version.
    public func health(port: Int, token: String) async -> HealthInfo? {
        guard let (status, body) = try? await transport.send(port: port, token: token, path: RunnerProtocol.healthPath, body: nil,
                                                             timeout: .seconds(3)), status == 200,
              let reply = try? JSONDecoder().decode(RunnerReply<HealthInfo>.self, from: body),
              let info = reply.result, info.protocolVersion == RunnerProtocol.version else { return nil }
        return info
    }

    /// Sends `request` and decodes the runner's reply. Throws `RunnerUnreachable` when the runner doesn't answer, and
    /// `runner_failed` when it answers with something xcd can't use (a refusal, or a body it can't read).
    public func call<Request: Encodable, Payload: Codable>(_ path: String, _ request: Request, port: Int, token: String,
                                                           timeout: Duration, as payload: Payload.Type) async throws -> Result<Payload, RunnerFailure> {
        let (status, body) = try await transport.send(port: port, token: token, path: path, body: try JSONEncoder().encode(request),
                                                      timeout: timeout)
        switch status {
        case 200:
            guard let reply = try? JSONDecoder().decode(RunnerReply<Payload>.self, from: body) else {
                throw XcdError(.runnerFailed, "the UI runner sent a reply xcd could not read",
                               next: "run `xcd ui stop`, then retry", details: [String(decoding: body.prefix(400), as: UTF8.self)])
            }
            if let result = reply.result, reply.ok { return .success(result) }
            return .failure(reply.failure ?? RunnerFailure(code: RunnerFailure.Code.internal, message: "the runner gave no result"))
        case 401:
            throw XcdError(.runnerFailed, "the UI runner rejected xcd's token", next: "run `xcd ui stop`, then retry")
        case 409:
            throw XcdError(.runnerFailed, "another ui command is running in this worktree", next: "wait for it to finish, then retry")
        case 400, 413:
            // The runner is alive and refused the request, so restarting it would not help, and neither would sending it again.
            throw XcdError(.runnerFailed, "the UI runner refused the request (HTTP \(status))",
                           next: "this is likely an xcd bug; run `xcd ui stop`, then retry")
        default:
            throw RunnerUnreachable(reason: "HTTP \(status)")
        }
    }
}
