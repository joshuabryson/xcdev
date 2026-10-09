import Foundation

/// The look `xcd open` makes for a route's `expect`: the runner's wait, with its two ways of
/// not finding the element kept apart from a runner that cannot be used.
extension UIService: ArrivalLooking {
    public func look(for target: String, timeout: Duration, device: String, in ctx: inout WorktreeContext) async throws -> ArrivalSight {
        let options = UIOptions(device: device, bundle: nil, system: false, role: nil, index: nil, timeout: timeout)
        let request = try targetRequest(target, gone: false, options, in: ctx)
        let exchange = RunnerExchange(path: RunnerProtocol.waitPath, request: request, what: "wait", resend: true)
        let (_, result) = try await send(exchange, as: ActionResult.self, options, in: &ctx)
        switch result {
        case .success(let action):
            return .found(seconds: Double(action.ms) / 1000)
        case .failure(let failure) where failure.code == RunnerFailure.Code.waitTimeout:
            return .missing(onScreen: failure.seen, away: nil)
        case .failure(let failure) where failure.code == RunnerFailure.Code.appNotForeground:
            // The runner kept looking while the app was away, and this is its answer when the time was up.
            return .missing(onScreen: [], away: failure.message)
        case .failure(let failure):
            throw UIRunnerErrors.error(failure, target: target, timeout: timeout)
        }
    }
}
