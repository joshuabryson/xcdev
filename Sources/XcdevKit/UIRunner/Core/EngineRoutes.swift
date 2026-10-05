import Foundation

/// The runner's HTTP surface: one request in, one JSON reply out.
extension RunnerEngine {
    /// The last-resort reply when even a plain failure can't be encoded.
    static let encodeFallback = #"{"ok":false,"failure":{"code":"internal","message":"could not encode the reply","candidates":[],"seen":[],"issues":[]}}"#

    static func reply<Payload: Codable>(_ outcome: Result<Payload, RunnerFailure>) -> Data {
        do {
            return try JSONEncoder().encode(RunnerReply(outcome))
        } catch {
            // A plain failure carries no frames or numbers, so it cannot fail the same way.
            let failure = RunnerFailure(code: RunnerFailure.Code.internal, message: "could not encode the reply: \(error)")
            return (try? JSONEncoder().encode(RunnerReply<HealthInfo>(.failure(failure)))) ?? Data(encodeFallback.utf8)
        }
    }

    static func decoded<Request: Decodable>(_ type: Request.Type, from body: Data) -> Result<Request, RunnerFailure> {
        do {
            return .success(try JSONDecoder().decode(type, from: body))
        } catch {
            return .failure(RunnerFailure(code: RunnerFailure.Code.badRequest, message: "the request body is not a valid \(type): \(error)"))
        }
    }

    /// Reads the body as `type`, runs `action`, and encodes what it returns.
    func answering<Request: Decodable, Payload: Codable>(_ type: Request.Type,
                                                         _ action: @escaping (Request) -> Result<Payload, RunnerFailure>) -> (Data) -> Data {
        { body in Self.reply(Self.decoded(type, from: body).flatMap(action)) }
    }

    var health: HealthInfo { HealthInfo(protocolVersion: RunnerProtocol.version, runner: runnerBundleId, rolesVerified: rolesVerified) }

    /// What answers `path`; nil for a path the runner doesn't serve.
    func responder(for path: String) -> ((Data) -> Data)? {
        switch path {
        case RunnerProtocol.healthPath: return { _ in Self.reply(Result<HealthInfo, RunnerFailure>.success(self.health)) }
        case RunnerProtocol.treePath: return answering(TreeRequest.self, tree)
        case RunnerProtocol.tapPath: return answering(TargetRequest.self, tap)
        case RunnerProtocol.waitPath: return answering(TargetRequest.self, wait)
        case RunnerProtocol.longPressPath: return answering(TargetRequest.self, longPress)
        case RunnerProtocol.swipePath: return answering(SwipeRequest.self, swipe)
        case RunnerProtocol.typePath: return answering(TypeRequest.self, enterText)
        default: return nil
        }
    }

    /// Never throws: a request the engine can't read, or a path it doesn't serve, is a `bad_request` reply.
    public func handle(path: String, body: Data) -> Data {
        guard let respond = responder(for: path) else {
            return Self.reply(Result<HealthInfo, RunnerFailure>.failure(
                RunnerFailure(code: RunnerFailure.Code.badRequest, message: "unknown path \(path)")))
        }
        return respond(body)
    }
}
