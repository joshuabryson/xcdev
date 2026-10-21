import Testing
@testable import XcdevKit

/// The Mac driver's refusals and its timeout, as xcd errors with their own `next:`.
@Suite struct UIRunnerErrorsTests {
    func error(_ code: String, _ message: String) -> XcdError {
        UIRunnerErrors.error(RunnerFailure(code: code, message: message), target: "id:name", timeout: .seconds(1))
    }

    /// The message names the keyboard, so it must not get the simulator's "dismiss the keyboard" advice.
    @Test func aFieldThatWouldNotTakeFocusSaysToLookAtTheWindow() {
        let refused = error(RunnerFailure.Code.notHittable, "the element would not take keyboard focus")
        #expect(refused.code == .elementNotHittable && refused.message == "id:name is not hittable: would not take keyboard focus")
        #expect(refused.next == "the window may be minimized or mostly off screen: `xcd ui screenshot` to see it, or name another field")
    }

    @Test func anElementWithNoPressActionSaysToGiveItOne() {
        let refused = error(RunnerFailure.Code.notHittable, "the element has no press action")
        #expect(refused.code == .elementNotHittable && refused.message == "id:name has no press action")
        #expect(refused.next == "give the view an accessibility action or identifier, or tap an element inside it")
    }

    @Test func aSwipeOnAnElementOutsideAnyScrollAreaSaysWhereToSwipe() {
        let refused = error(RunnerFailure.Code.notHittable, "no scroll area encloses it")
        #expect(refused.code == .elementNotHittable && refused.message == "id:name is not hittable: no scroll area encloses it")
        #expect(refused.next == "name an element inside a scroll view, or swipe without --on")
    }

    /// `RunnerEngine.tree` wraps every read failure as `internal`, with the driver's message inside its own.
    @Test func anAppThatDoesNotAnswerIsRunnerFailedNamingTheSystemPrompt() {
        let failed = error(RunnerFailure.Code.internal, "could not read the screen: \(MacDriver.notAnswering)")
        #expect(failed.code == .runnerFailed && failed.message == MacDriver.notAnswering)
        #expect(failed.next == "run `xcd ui screenshot` to see the window, or ask the user whether a system prompt is up")
        let keyboard = error(RunnerFailure.Code.notHittable, "the element is covered by the keyboard")
        #expect(keyboard.next == "dismiss the keyboard first (tap its Return or Done key), then retry")
    }
}
