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
        RunnerFailure.Code.appCrashed: appCrashed,
        RunnerFailure.Code.unsupported: unsupported,
        RunnerFailure.Code.nothingFocused: nothingFocused,
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

    /// What to do for each reason an element is not hittable, by a word of the reason, the first match winning. The
    /// Mac driver's refusals come first: "would not take keyboard focus" names the keyboard, but no keyboard is up.
    static let notHittableNexts: [(reason: String, next: String)] = [
        ("would not take keyboard focus", "the window may be minimized or mostly off screen: `xcd ui screenshot` to see it, or name another field"),
        ("has no press action", "give the view an accessibility action or identifier, or tap an element inside it"),
        ("no scroll area encloses it", "name an element inside a scroll view, or swipe without --on"),
        ("disabled", "it can't be tapped while disabled; do what enables it first"),
        ("system alert", "answer the system alert first (`xcd ui tree` lists its buttons), then retry"),
        ("keyboard", "dismiss the keyboard first (tap its Return or Done key), then retry"),
        ("no size", "wait for it to lay out (`xcd ui wait`), then retry; `xcd ui tree --all` lists every element"),
    ]

    /// The runner says why: disabled, no size, off screen, or covered by a system alert or the keyboard; the Mac
    /// driver also says when an element takes no focus, has no press action, or is in no scroll area.
    static func notHittable(_ failure: RunnerFailure, target: String, _: Duration) -> XcdError {
        let reason = failure.message.hasPrefix("the element ") ? String(failure.message.dropFirst("the element ".count)) : failure.message
        let message = "\(target) \(reason.hasPrefix("is ") || reason.hasPrefix("has ") ? reason : "is not hittable: \(reason)")"
            + (failure.frame.map { " (\($0.text))" } ?? "")
        let next = notHittableNexts.first { failure.message.contains($0.reason) }?.next
            ?? "scroll it into view, then retry; `xcd ui tree --all` lists off-screen elements"
        return XcdError(.elementNotHittable, message, next: next)
    }

    static func ambiguous(_ failure: RunnerFailure, target: String, _: Duration) -> XcdError {
        XcdError(.elementAmbiguous, "\(failure.candidates.count) elements match \(target)",
                 next: "pick one: pass `ref:eN` (or just `eN`) from the list, `--index <n>` (0 is the first), or `--role <role>`",
                 details: UIText.rows(failure.candidates))
    }

    /// A ref that is in no table is from an earlier tree (or was never given out); one that is has lost its element.
    static func staleRef(_ failure: RunnerFailure, target: String, _: Duration) -> XcdError {
        guard failure.message == RunnerEngine.unknownRef else {
            return XcdError(.staleRef, "\(target) no longer names one element on screen", next: "run `xcd ui tree` and use a ref from it")
        }
        return XcdError(.staleRef, "\(target) is not a ref of the latest tree",
                        next: "a ref lasts while each new tree lists its element; run `xcd ui tree` and use a ref from it, "
                            + "or aim with `id:` or `label:`, which need no tree")
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

    /// `UIService` adds the crash report when it can find one; this is the error without it.
    static func appCrashed(_ failure: RunnerFailure, target _: String, _: Duration) -> XcdError {
        XcdError(.appCrashed, failure.message, next: "see its last output with `xcd logs --app`, then start it again with `xcd run`")
    }

    static func unsupported(_ failure: RunnerFailure, target _: String, _: Duration) -> XcdError {
        XcdError(.platformUnsupported, failure.message, next: "pick a device from .xcdev.yml that can do this with `--device <name>`, or leave this step out")
    }

    static func badRequest(_ failure: RunnerFailure, target _: String, _: Duration) -> XcdError {
        XcdError(.runnerFailed, "the UI runner refused the request: \(failure.message)",
                 next: "this is likely an xcd bug; run `xcd ui stop`, then retry", details: failure.issues)
    }

    /// Text was typed with no field focused. With no keyboard up the runner says so itself; with one up XCTest does.
    static func nothingFocused(_ failure: RunnerFailure, target _: String, _: Duration) -> XcdError {
        XcdError(.elementNotFound, "nothing has keyboard focus, so there was nowhere to type",
                 next: "focus a field first: pass `--into <target>`, or tap it", details: failure.issues)
    }

    static func internalFailure(_ failure: RunnerFailure, target: String, timeout: Duration) -> XcdError {
        // The Mac driver's timeout, which `RunnerEngine.tree` wraps in its own words.
        if failure.message.contains(MacDriver.notAnswering) {
            return XcdError(.runnerFailed, MacDriver.notAnswering,
                            next: "run `xcd ui screenshot` to see the window, or ask the user whether a system prompt is up")
        }
        // XCTest's own words when text is typed with no field focused.
        if failure.issues.contains(where: { $0.localizedCaseInsensitiveContains("keyboard focus") }) {
            return nothingFocused(failure, target: target, timeout)
        }
        return XcdError(.runnerFailed, failure.message, next: "run `xcd ui stop`, then retry; `xcd doctor` if it keeps happening",
                        details: failure.issues)
    }
}
