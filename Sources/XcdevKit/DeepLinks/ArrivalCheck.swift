import Foundation

/// What one look for a route's `expect` saw.
public enum ArrivalSight: Sendable, Equatable {
    case found(seconds: Double)
    /// Not on screen when the time was up. `onScreen` names what was. `away` says why when the app was not in
    /// front: a link that opened somewhere else, such as an https link Safari took, leaves the app behind.
    case missing(onScreen: [String], away: String?)
}

/// Looks for an element in this worktree's app. `UIService` does it through the UI runner.
public protocol ArrivalLooking: Sendable {
    /// Waits up to `timeout` for `target` to be on screen in the app last built for `device`. Throws when the look
    /// could not be made at all: the runner cannot be built or started, or no app has been built.
    func look(for target: String, timeout: Duration, device: String, in ctx: inout WorktreeContext) async throws -> ArrivalSight
}

/// How a route's arrival check goes for one delivery.
enum ArrivalPlan: Sendable, Equatable {
    /// The route has no `expect`, or nothing went out that could be checked.
    case none
    /// UI driving does not work on this device.
    case skipped(target: String, reason: String)
    /// The element was on screen before the link went to a copy that was already up, so seeing it proves nothing.
    case inconclusive(target: String)
    case look(target: String, device: String)
}

/// What an arrival check found: the report's `check`, and the failure when the element was not there or the look
/// could not be made.
struct ArrivalResult: Sendable {
    var check: OpenReport.Check?
    var failure: XcdError?
}

enum ArrivalCheck {
    /// How long the element has to show up after a delivery.
    static let wait: Duration = .seconds(10)
    static let onMac = "the arrival check needs UI driving, which works on iPhone and iPad simulators only"

    /// The result of the look that followed a delivery. `sent` says what reached the device ("the link was sent"),
    /// so a failure tells the agent that the device changed. `web` is true for an http or https link.
    static func result(_ sight: ArrivalSight, _ target: String, after sent: String, web: Bool) -> ArrivalResult {
        switch sight {
        case .found(let seconds):
            return ArrivalResult(check: OpenReport.Check(target: target, outcome: .appeared, seconds: seconds, reason: nil))
        case .missing(let onScreen, let away):
            let check = OpenReport.Check(target: target, outcome: .missing, seconds: DurationText.seconds(wait), reason: away)
            let message = "\(sent), but \(target) did not appear within \(DurationText.format(wait))"
            return ArrivalResult(check: check, failure: XcdError(.waitTimeout, message, next: next(onScreen: onScreen, away: away, web: web)))
        }
    }

    /// What to do about an element that did not show. An app that was not in front is where a link that opened
    /// somewhere else ends: Safari takes an https link unless the app's associated domains work on the simulator.
    static func next(onScreen: [String], away: String?, web: Bool) -> String {
        if let away {
            let why = web ? ": an https link opens in Safari unless the app's associated domains work on this simulator" : ""
            return away + why + "; see what is in front with `xcd ui tree --system`"
        }
        guard !onScreen.isEmpty else { return "run `xcd ui tree` to see what is on screen" }
        return "on screen now: \(onScreen.prefix(8).joined(separator: ", ")); run `xcd ui tree`"
    }

    /// The result of a look that could not be made. A route with `expect` promises a check, so this is a failure and
    /// not a skip: it keeps the error's code and `next`, and its message says what had already reached the device.
    static func unchecked(_ error: any Error, _ target: String, after sent: String) -> ArrivalResult {
        var failure = error as? XcdError ?? XcdError(.runnerFailed, "\(error)", next: "run `xcd ui stop`, then retry")
        let reason = failure.message
        failure.message = "\(sent), but the arrival check could not run: \(reason)"
        return ArrivalResult(check: OpenReport.Check(target: target, outcome: .failed, seconds: nil, reason: reason), failure: failure)
    }
}

extension RouteService {
    /// Why the arrival check cannot run on this device, when it cannot: UI driving is for iPhone and iPad
    /// simulators on iOS 17 or later.
    func arrivalUnavailable(on device: String, in ctx: WorktreeContext) -> String? {
        if ctx.config.allDevices[device]?.isMac == true { return ArrivalCheck.onMac }
        guard let clone = ctx.state.devices[device] else { return nil }
        do {
            try Runners.requireIOS(clone, name: device)
            return nil
        } catch {
            return (error as? XcdError)?.message ?? "\(error)"
        }
    }

    /// How the route's `expect` is checked on `device`: not at all without one, and skipped where UI driving does
    /// not work.
    func arrivalPlan(_ route: ResolvedRoute, on device: String, in ctx: WorktreeContext) -> ArrivalPlan {
        guard let target = route.expect else { return .none }
        if let reason = arrivalUnavailable(on: device, in: ctx) { return .skipped(target: target, reason: reason) }
        return .look(target: target, device: device)
    }

    /// One look before a link goes to a copy that is already up: the runner's wait returns at once for an element
    /// that is already there, whether or not the link did anything. A look that cannot be made counts as not seen;
    /// the look after the delivery says what is wrong.
    func alreadyThere(_ plan: ArrivalPlan, in ctx: inout WorktreeContext) async -> Bool {
        guard case .look(let target, let device) = plan,
              case .found? = try? await arrival.look(for: target, timeout: .zero, device: device, in: &ctx) else { return false }
        return true
    }

    /// Carries out the plan once the route was delivered.
    func arrive(_ plan: ArrivalPlan, after route: ResolvedRoute, in ctx: WorktreeContext) async -> ArrivalResult {
        switch plan {
        case .none:
            return ArrivalResult()
        case .skipped(let target, let reason):
            return ArrivalResult(check: OpenReport.Check(target: target, outcome: .skipped, seconds: nil, reason: reason))
        case .inconclusive(let target):
            return ArrivalResult(check: OpenReport.Check(target: target, outcome: .inconclusive, seconds: nil,
                                                         reason: "\(target) was already on screen"))
        case .look(let target, let device):
            let sent = OpenReport.sent(route.delivery.kind)
            // The device is cloned and booted by now, so the look changes nothing in the context: its copy is dropped.
            var context = ctx
            do {
                let sight = try await arrival.look(for: target, timeout: ArrivalCheck.wait, device: device, in: &context)
                return ArrivalCheck.result(sight, target, after: sent, web: route.isWebLink)
            } catch {
                return ArrivalCheck.unchecked(error, target, after: sent)
            }
        }
    }
}
