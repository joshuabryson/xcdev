import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// A route's check that found its element, though nothing shows that the link brought it there: the command fails with
/// `arrival_unproven`, and the whole result is still printed.
@Suite struct ArrivalUnprovenTests {
    static let config = """
    version: 1
    project: App.xcodeproj
    deeplinks:
      routes:
        named:
          description: "An expect that names the parameter"
          url: "app://item/{id}"
          expect: "label~Item {id}"
          params: { id: {} }
        vague:
          description: "An expect that names none of the parameters"
          url: "app://item/{id}?tab={tab}"
          expect: "id:item-detail"
          params: { tab: { default: notes }, id: {} }
        plain:
          description: "No parameters"
          url: "app://home"
          expect: "id:home"
    """

    func route(_ name: String, _ values: [String: String] = [:]) throws -> ResolvedRoute {
        try RouteResolver(config: try ConfigLoader.parse(main: Self.config)).resolve(.route(name: name, values: values))
    }

    /// The result of delivering `route` when its check ended with `outcome`.
    func report(_ route: ResolvedRoute, _ outcome: CheckOutcome, reason: String? = nil) -> OpenReport {
        var report = OpenReport(route, device: "iphone", dryRun: false, worktree: "feat")
        report.linkSent = true
        report.arrived(ArrivalResult(check: OpenReport.Check(target: route.expect ?? "", outcome: outcome, seconds: nil, reason: reason)))
        return report
    }

    @Test func anUnprovenArrivalFailsWithExit2AndSaysWhatToDo() throws {
        let failure = try #require(report(try route("named", ["id": "42"]), .inconclusive, reason: "label~Item 42 was already on screen").failure)
        #expect(failure.code == .arrivalUnproven && failure.code.exitCode == 2)
        #expect(failure.message == "the link was sent, and label~Item 42 is on screen, but that does not show the link brought it there")
        #expect(failure.next == "open it again with `--cold` or a preset, which restart the app, to see the screen arrive")
    }

    /// An element that does not depend on the route's parameters may be on screen whichever item the link names.
    @Test func aRouteWhoseExpectNamesNoneOfItsParametersIsToldToNameOne() throws {
        #expect(try route("named", ["id": "42"]).unnamedParameter == nil)
        #expect(try route("plain").unnamedParameter == nil)
        #expect(try route("vague", ["id": "42"]).unnamedParameter == "id")              // the first parameter by name
        let failure = try #require(report(try route("vague", ["id": "42"]), .inconclusive).failure)
        #expect(failure.next == "open it again with `--cold` or a preset, which restart the app, to see the screen arrive; "
                    + "or give the route an `expect` that names one of its parameters, such as \"label~{id}\"")
    }

    /// The failures that come before it are unchanged, and a check that could not be made where UI driving does not
    /// work is still a success.
    @Test func anAppThatEndedStillWinsAndASkippedCheckStillSucceeds() throws {
        var ended = report(try route("vague", ["id": "1"]), .inconclusive)
        ended.exitedAfter = 0.5
        #expect(ended.failure?.code == .appCrashed)
        #expect(report(try route("vague", ["id": "1"]), .skipped, reason: "the arrival check needs UI driving").failure == nil)
        #expect(report(try route("vague", ["id": "1"]), .appeared).failure == nil)
    }

    @Test func theWholeResultIsPrintedBeforeTheFailure() throws {
        let unproven = report(try route("named", ["id": "42"]), .inconclusive, reason: "label~Item 42 was already on screen")
        let text = Renderer.report(unproven, command: "open", format: .text)
        #expect(text.hasSuffix("\nurl: app://item/42\ncheck: inconclusive (label~Item 42 was already on screen)\n"
                                   + "next: open it again with `--cold` or a preset, which restart the app, to see the screen arrive"))
        let json = Renderer.report(unproven, command: "open", format: .json)
        #expect(json.contains(#""ok":false"#) && json.contains(#""code":"arrival_unproven""#) && json.contains(#""outcome":"inconclusive""#))
    }

    @Test func helpErrorsListsTheCode() {
        let row = ErrorsReport().errors.first { $0.code == "arrival_unproven" }
        #expect(row?.exitCode == 2 && row?.summary.hasPrefix("`xcd open` found the route's `expect` on screen") == true)
    }
}
