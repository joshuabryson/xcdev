import Foundation

/// The runner's failure codes as xcd errors that say what to do next. Every code the runner can send has
/// an entry; one xcd doesn't know is reported as `runner_failed` with the code in the message.
enum UIRunnerErrors {
    typealias Mapper = @Sendable (_ failure: RunnerFailure, _ target: String, _ timeout: Duration) -> XcdError

    static let mappers: [String: Mapper] = [
        RunnerFailure.Code.notFound: notFound,
        RunnerFailure.Code.notHittable: notHittable,
        RunnerFailure.Code.ambiguous: ambiguous,
        RunnerFailure.Code.staleRef: staleRef,
        RunnerFailure.Code.waitTimeout: waitTimeout,
        RunnerFailure.Code.appNotForeground: appNotForeground,
        RunnerFailure.Code.badRequest: badRequest,
        RunnerFailure.Code.internal: internalFailure,
    ]

    static func error(_ failure: RunnerFailure, target: String, timeout: Duration) -> XcdError {
        guard let mapper = mappers[failure.code] else {
            return XcdError(.runnerFailed, "the UI runner reported \(failure.code): \(failure.message)",
                            next: "run `xcd ui stop`, then retry; `xcd doctor` if it keeps happening", details: failure.issues)
        }
        return mapper(failure, target, timeout)
    }

    static func notFound(_ failure: RunnerFailure, target: String, _: Duration) -> XcdError {
        let wanted = text(of: target)
        let close = Suggest.closest(to: wanted, in: failure.seen, limit: 5)
        return XcdError(.elementNotFound, "\(failure.message) \(target)",
                        next: close.isEmpty ? "run `xcd ui tree` to see what is on screen"
                                            : "closest on screen: \(close.joined(separator: ", ")); run `xcd ui tree` to see everything")
    }

    /// The text a target looks for, without its `id:`, `label:`, `label~`, or `ref:` prefix, to compare with what is on screen.
    static func text(of target: String) -> String {
        switch TargetParser.parse(target) {
        case .success(.id(let text)), .success(.label(let text)), .success(.labelContains(let text)), .success(.ref(let text)):
            return text
        case .success(.point), .failure:
            return target
        }
    }

    /// The runner says why: disabled, no size, off screen, or covered by a system alert or the keyboard.
    static func notHittable(_ failure: RunnerFailure, target: String, _: Duration) -> XcdError {
        let reason = failure.message.hasPrefix("the element ") ? String(failure.message.dropFirst("the element ".count)) : failure.message
        let message = "\(target) \(reason.hasPrefix("is ") || reason.hasPrefix("has ") ? reason : "is not hittable: \(reason)")"
            + (failure.frame.map { " (\($0.text))" } ?? "")
        let next: String
        if failure.message.contains("disabled") {
            next = "it can't be tapped while disabled; do what enables it first"
        } else if failure.message.contains("system alert") {
            next = "answer the system alert first (`xcd ui tree` lists its buttons), then retry"
        } else if failure.message.contains("keyboard") {
            next = "dismiss the keyboard first (tap its Return or Done key), then retry"
        } else if failure.message.contains("no size") {
            next = "wait for it to lay out (`xcd ui wait`), then retry; `xcd ui tree --all` lists every element"
        } else {
            next = "scroll it into view, then retry; `xcd ui tree --all` lists off-screen elements"
        }
        return XcdError(.elementNotHittable, message, next: next)
    }

    static func ambiguous(_ failure: RunnerFailure, target: String, _: Duration) -> XcdError {
        XcdError(.elementAmbiguous, "\(failure.candidates.count) elements match \(target)",
                 next: "pick one: pass `ref:eN` from the list (these refs replace any refs from an earlier tree), "
                     + "`--index <n>` (0 is the first), or `--role <role>`",
                 details: UIText.rows(failure.candidates))
    }

    static func staleRef(_: RunnerFailure, target: String, _: Duration) -> XcdError {
        XcdError(.staleRef, "\(target) no longer names one element on screen", next: "run `xcd ui tree` and use a ref from it")
    }

    static func waitTimeout(_ failure: RunnerFailure, target: String, timeout: Duration) -> XcdError {
        let appeared = failure.message.contains("did not appear")
        return XcdError(.waitTimeout, "\(target) \(appeared ? "did not appear within" : "is still on screen after") \(DurationText.format(timeout))",
                        next: failure.seen.isEmpty ? "run `xcd ui tree`"
                                                   : "on screen now: \(failure.seen.prefix(8).joined(separator: ", ")); run `xcd ui tree`")
    }

    static func appNotForeground(_ failure: RunnerFailure, target: String, _: Duration) -> XcdError {
        XcdError(.elementNotFound, "\(target): the app isn't in the foreground (\(failure.message))",
                 next: "bring the app to the foreground with `xcd launch` or `xcd run`, then retry")
    }

    static func badRequest(_ failure: RunnerFailure, target _: String, _: Duration) -> XcdError {
        XcdError(.runnerFailed, "the UI runner refused the request: \(failure.message)",
                 next: "this is likely an xcd bug; run `xcd ui stop`, then retry", details: failure.issues)
    }

    static func internalFailure(_ failure: RunnerFailure, target _: String, _: Duration) -> XcdError {
        XcdError(.runnerFailed, failure.message, next: "run `xcd ui stop`, then retry; `xcd doctor` if it keeps happening",
                 details: failure.issues)
    }
}
