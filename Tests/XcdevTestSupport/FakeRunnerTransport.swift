import Foundation
import Synchronization
import XcdevKit

/// Answers runner requests from a closure and records the paths asked for.
public final class FakeRunnerTransport: RunnerTransport {
    public typealias Handler = @Sendable (_ path: String, _ body: Data?) throws -> (status: Int, body: Data)

    private let state: Mutex<(handler: Handler, calls: [String])>

    public init(_ handler: @escaping Handler = FakeRunnerTransport.healthy) {
        state = Mutex((handler, []))
    }

    public var calls: [String] { state.withLock { $0.calls } }
    public func setHandler(_ handler: @escaping Handler) { state.withLock { $0.handler = handler } }

    public func send(port: Int, token: String, path: String, body: Data?, timeout: Duration) async throws -> (status: Int, body: Data) {
        let handler = state.withLock { state -> Handler in
            state.calls.append(path)
            return state.handler
        }
        return try handler(path, body)
    }

    /// A 200 reply carrying `outcome` in the runner's envelope.
    public static func reply<Payload: Codable>(_ outcome: Result<Payload, RunnerFailure>) -> (status: Int, body: Data) {
        (200, (try? JSONEncoder().encode(RunnerReply(outcome))) ?? Data())
    }

    /// Answers `/health` like a current runner; anything else is a bad request.
    public static let healthy: Handler = { path, _ in
        guard path == RunnerProtocol.healthPath else {
            return reply(Result<HealthInfo, RunnerFailure>.failure(RunnerFailure(code: RunnerFailure.Code.badRequest, message: "unstubbed \(path)")))
        }
        return reply(Result<HealthInfo, RunnerFailure>.success(
            HealthInfo(protocolVersion: RunnerProtocol.version, runner: RunnerSource.runnerBundleId, rolesVerified: true)))
    }
}
