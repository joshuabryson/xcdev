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
    /// The route has no `expect`, or there is nothing to check: the link did not go out, or the app crashed as it
    /// started.
    case none
    /// UI driving does not work on this device.
    case skipped(target: String, reason: String)
    /// The element was on screen before the link went to a copy that was already up, so seeing it proves nothing.
    case inconclusive(target: String)
    /// `unsure` is why the look before the link to a copy that was already up could not tell whether the element was
    /// on screen. The element may then have been there all along, so a find by the look afterwards proves nothing,
    /// however long it took.
    case look(target: String, device: String, unsure: String? = nil)
}

/// What the one look before a link to a copy that is already up saw.
enum EarlierSight: Sendable, Equatable {
    /// The app was in front, and the element was not on screen.
    case notSeen
    /// The element was on screen.
    case seen
    /// The look could not see the app: it was not in front, or the look could not be made. `why` says so.
    case couldNotTell(why: String)
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

    /// The result of a look after a delivery when the look before it could not tell whether the element was already
    /// on screen (`why`): the element may have been there all along, so any find is inconclusive, however long it
    /// took. A look that did not find the element, or that could not be made, is a failure as it stands.
    static func doubted(_ result: ArrivalResult, because why: String?) -> ArrivalResult {
        guard let why, let check = result.check, check.outcome == .appeared else { return result }
        let reason = "xcd could not look before the link was sent (\(why)), so \(check.target) may already have been on screen"
        return ArrivalResult(check: OpenReport.Check(target: check.target, outcome: .inconclusive, seconds: nil, reason: reason))
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

    /// The result of a look that could not be made after `route` was delivered to `device`. A route with `expect`
    /// promises a check, so this is a failure and not a skip: it keeps the error's code, and its message says what
    /// had already reached the device. It keeps the error's `next` too, except for an app that is not built: that
    /// `next` is written for `xcd ui` and names flags `xcd open` does not take.
    static func unchecked(_ error: any Error, _ target: String, after route: ResolvedRoute, on device: String) -> ArrivalResult {
        var failure = error as? XcdError ?? XcdError(.runnerFailed, "\(error)", next: "run `xcd ui stop`, then retry")
        let reason = failure.message
        failure.message = "\(OpenReport.sent(route.delivery.kind)), but the arrival check could not run: \(reason)"
        if failure.code == .appNotBuilt { failure.next = notBuiltNext(route, on: device) }
        return ArrivalResult(check: OpenReport.Check(target: target, outcome: .failed, seconds: nil, reason: reason), failure: failure)
    }

    /// What to do when no app has been built for `device`, so xcd does not know which app to look in. Only a script
    /// route gets this far without a build, and its script may be where the build belongs.
    static func notBuiltNext(_ route: ResolvedRoute, on device: String) -> String {
        "build first with `xcd build --device \(device)` (or have the script build), then run `xcd open \(route.name ?? "<route>")` again"
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
    /// that is already there, whether or not the link did anything. A look that cannot see the app, because it is
    /// not in front or the look cannot be made, could not tell. That is not a failure here: the look after the
    /// delivery is still made, says what is wrong if it cannot be, and proves nothing if it finds the element.
    func alreadyThere(_ plan: ArrivalPlan, in ctx: inout WorktreeContext) async -> EarlierSight {
        guard case .look(let target, let device, _) = plan else { return .notSeen }
        do {
            switch try await arrival.look(for: target, timeout: .zero, device: device, in: &ctx) {
            case .found: return .seen
            case .missing(_, let away?): return .couldNotTell(why: away)
            case .missing: return .notSeen
            }
        } catch {
            return .couldNotTell(why: (error as? XcdError)?.message ?? "\(error)")
        }
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
        case .look(let target, let device, let unsure):
            let sent = OpenReport.sent(route.delivery.kind)
            // The device is cloned and booted by now, so the look changes nothing in the context: its copy is dropped.
            var context = ctx
            do {
                let sight = try await arrival.look(for: target, timeout: ArrivalCheck.wait, device: device, in: &context)
                let result = ArrivalCheck.result(sight, target, after: sent, web: route.isWebLink)
                return ArrivalCheck.doubted(result, because: unsure)
            } catch {
                return ArrivalCheck.unchecked(error, target, after: route, on: device)
            }
        }
    }
}
