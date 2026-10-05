import Foundation
import Synchronization
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The requests a fake runner was sent, in order.
final class SentRequests: Sendable {
    private let items = Mutex<[(path: String, body: Data)]>([])

    func add(_ path: String, _ body: Data) { items.withLock { $0.append((path, body)) } }
    var count: Int { items.withLock { $0.count } }

    /// The newest request's path, and its body decoded as `type`.
    func last<Request: Decodable>(as type: Request.Type) throws -> (path: String, request: Request) {
        let (path, body) = try #require(items.withLock { $0.last })
        return (path, try JSONDecoder().decode(type, from: body))
    }
}

/// `xcd ui long-press`, `swipe`, `type`, `button`, `rotate`, `--tree`, and what happens when an action ends the app.
@Suite struct UIActionsTests {
    let base = UIServiceTests()
    let options = UIOptions(device: nil, bundle: nil, system: false, role: nil, index: nil, timeout: .seconds(2))
    static let scope = ActionScope(bundleId: "dev.xcdev.App", system: false, timeout: 2, tree: false)

    /// A service whose runner answers every action with `result`, and the requests it was sent.
    func setup(_ result: ActionResult) throws -> (UIService, WorktreeContext, SentRequests) {
        let sent = SentRequests()
        let (service, ctx, _, _) = try base.setup { path, body in
            sent.add(path, body ?? Data())
            return FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.success(result))
        }
        return (service, ctx, sent)
    }
    @Test func treeAfterATapIsPrintedUnderIt() async throws {
        defer { base.worktree.remove() }
        var result = ActionResult(element: UIServiceTests.element, x: 201, y: 725, ms: 812)
        result.tree = UIServiceTests.tree
        var (service, ctx, sent) = try setup(result)
        var asking = options
        asking.tree = true
        let report = try await service.tap("id:signIn", asking, in: &ctx)
        #expect(try sent.last(as: TargetRequest.self).request.tree == true)
        #expect(report.text == """
        tapped button "Sign In" id=signIn at 201,725  812ms
        app dev.xcdev.App (foreground)  screen 402x874pt @3x  portrait  keyboard: hidden
        e1  button     "Sign In"  id=signIn  24,700 354x50
        e2  textField  (no label)  value=""  placeholder="Email"  id=email  24,300 354x44
        e3  button     "Allow"  57,457 288x48  disabled  selected  system
        """)
        #expect(report.tree == UIServiceTests.tree)
        _ = try await service.tap("id:signIn", options, in: &ctx)
        #expect(try sent.last(as: TargetRequest.self).request.tree == false)
    }

    @Test func aTreeThatCouldNotBeReadIsNoted() async throws {
        defer { base.worktree.remove() }
        var (service, ctx, _) = try setup(ActionResult(element: nil, x: 1, y: 2, ms: 5))
        var asking = options
        asking.tree = true
        #expect(try await service.tap("@1,2", asking, in: &ctx).text
                == "tapped @1,2  5ms\nnote: the tree could not be read after the action; run `xcd ui tree`")
        #expect(try await service.tap("@1,2", options, in: &ctx).text == "tapped @1,2  5ms")
    }

    @Test func anActionThatEndsTheAppReportsItsCrash() async throws {
        defer { base.worktree.remove() }
        let (plain, context, _, detached) = try base.setup { _, _ in
            FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.failure(
                RunnerFailure(code: RunnerFailure.Code.appCrashed, message: "the app is no longer running after the tap")))
        }
        var ctx = context
        let reports = base.worktree.root + "/DiagnosticReports"
        try FileManager.default.createDirectory(atPath: reports, withIntermediateDirectories: true)
        let started = Date()
        let service = UIService(supervisor: plain.supervisor, client: plain.client, crashes: CrashReportLocator(directory: reports),
                                now: { started })
        let none = await #expect(throws: XcdError.self) { _ = try await service.tap("id:signIn", options, in: &ctx) }
        #expect(none?.code == .appCrashed && none?.code.exitCode == 1)
        #expect(none?.message == "the app stopped running during the tap (no crash report found)")
        #expect(none?.next == "see its last output with `xcd logs --app`, then start it again with `xcd run`")

        // The build's process is "App", so its report is App-*.ips.
        try Fixture.string("crash-sim.ips").write(toFile: reports + "/App-2026-10-04-191010.ips", atomically: true, encoding: .utf8)
        let crash = await #expect(throws: XcdError.self) { _ = try await service.tap("id:signIn", options, in: &ctx) }
        #expect(crash?.code == .appCrashed && crash?.message.hasPrefix("the app crashed during the tap: EXC_") == true, "\(String(describing: crash))")
        #expect(crash?.details.last == "report: \(reports)/App-2026-10-04-191010.ips" && (crash?.details.count ?? 0) > 1)
        #expect(crash?.next == "fix the crash, then start the app again with `xcd run`")

        // Another app's process name isn't known, so no report is looked for.
        var other = options
        other.bundle = "com.example.other"
        let unknown = await #expect(throws: XcdError.self) { _ = try await service.tap("id:signIn", other, in: &ctx) }
        #expect(unknown?.message == "the app stopped running during the tap (no crash report found)")
        #expect(detached.starts.count == 1)                                 // the runner itself was never restarted
    }
    @Test func aLongPressSendsItsDurationAndReportsIt() async throws {
        defer { base.worktree.remove() }
        var (service, ctx, sent) = try setup(ActionResult(element: UIServiceTests.element, x: 201, y: 725, ms: 2600))
        let report = try await service.longPress("id:signIn", duration: .milliseconds(2500), options, in: &ctx)
        let (path, request) = try sent.last(as: TargetRequest.self)
        #expect(path == "/longpress" && request.duration == 2.5 && request.target == .id("signIn") && request.tree == false)
        #expect(report.text == #"long-pressed button "Sign In" id=signIn at 201,725 for 2.5s  2600ms"#)
        for bad in [Duration.milliseconds(50), .seconds(21)] {
            let error = await #expect(throws: XcdError.self) { _ = try await service.longPress("id:signIn", duration: bad, options, in: &ctx) }
            #expect(error?.code == .usage && error?.next == "pass a duration like 1s or 2.5s")
        }
        #expect(sent.count == 1)
    }

    @Test func aDirectionSwipeNamesItsElementOrTheScreen() async throws {
        defer { base.worktree.remove() }
        var result = ActionResult(element: UIServiceTests.element, x: 201, y: 725, ms: 420)
        result.toX = 201
        result.toY = 705
        var (service, ctx, sent) = try setup(result)
        var withRole = options
        withRole.role = "button"
        let report = try await service.swipe(SwipeOptions(direction: "up", on: "id:signIn", from: nil, to: nil), withRole, in: &ctx)
        let (path, request) = try sent.last(as: SwipeRequest.self)
        #expect(path == "/swipe")
        #expect(request == SwipeRequest(scope: Self.scope, direction: .up, on: ElementQuery(target: .id("signIn"), role: "button", index: nil),
                                        from: nil, to: nil))
        #expect(report.text == #"swiped up on button "Sign In" id=signIn at 201,725 to 201,705  420ms"#)
        #expect(report.toX == 201 && report.toY == 705)
    }

    @Test func aSwipeAcrossTheScreenOrBetweenPointsSaysWhereItWent() async throws {
        defer { base.worktree.remove() }
        var result = ActionResult(element: nil, x: 201, y: 437, ms: 400)
        result.toX = 201
        result.toY = 87.4
        var (service, ctx, sent) = try setup(result)
        #expect(try await service.swipe(SwipeOptions(direction: "up", on: nil, from: nil, to: nil), options, in: &ctx).text
                == "swiped up on the screen from 201,437 to 201,87.4  400ms")
        #expect(try sent.last(as: SwipeRequest.self).request == SwipeRequest(scope: Self.scope, direction: .up, on: nil, from: nil, to: nil))
        #expect(try await service.swipe(SwipeOptions(direction: nil, on: nil, from: "201,437", to: "@201,87.4"), options, in: &ctx).text
                == "swiped from 201,437 to 201,87.4  400ms")
        #expect(try sent.last(as: SwipeRequest.self).request == SwipeRequest(scope: Self.scope, direction: nil, on: nil,
                                                                              from: ScreenPoint(x: 201, y: 437), to: ScreenPoint(x: 201, y: 87.4)))
    }

    @Test func aSwipeThatCannotBeReadIsAUsageError() async throws {
        defer { base.worktree.remove() }
        var (service, ctx, sent) = try setup(ActionResult(element: nil, x: 0, y: 0, ms: 0))
        let cases: [(SwipeOptions, String)] = [
            (SwipeOptions(direction: nil, on: nil, from: nil, to: nil), "a swipe needs a direction, or both --from and --to"),
            (SwipeOptions(direction: nil, on: nil, from: "1,2", to: nil), "a swipe needs a direction, or both --from and --to"),
            (SwipeOptions(direction: nil, on: "id:list", from: "1,2", to: "3,4"), "a swipe needs a direction, or both --from and --to"),
            (SwipeOptions(direction: "sideways", on: nil, from: nil, to: nil), "'sideways' is not a direction"),
            (SwipeOptions(direction: "up", on: nil, from: "1,2", to: "3,4"), "a direction and --from/--to can't be combined"),
            (SwipeOptions(direction: "up", on: "@1,2", from: nil, to: nil), "--on takes an element, not a point"),
            (SwipeOptions(direction: "up", on: "the list", from: nil, to: nil), "'the list' is not a target"),
            (SwipeOptions(direction: nil, on: nil, from: "left", to: "3,4"), "--from left is not a point"),
        ]
        for (swipe, message) in cases {
            let error = await #expect(throws: XcdError.self) { _ = try await service.swipe(swipe, options, in: &ctx) }
            #expect(error?.code == .usage && error?.message == message && error?.next?.isEmpty == false, "\(message)")
        }
        #expect(sent.count == 0)
    }

    @Test func typingSaysHowManyCharactersWhereAndHow() async throws {
        defer { base.worktree.remove() }
        var result = ActionResult(element: UIServiceTests.tree.elements[1], x: 201, y: 322, ms: 1320)
        result.method = "keyboard"
        var (service, ctx, sent) = try setup(result)
        let report = try await service.type("me@example.com", TypeOptions(into: "id:email", clear: true, submit: true), options, in: &ctx)
        let (path, request) = try sent.last(as: TypeRequest.self)
        #expect(path == "/type")
        #expect(request == TypeRequest(scope: Self.scope, text: "me@example.com", into: ElementQuery(target: .id("email"), role: nil, index: nil),
                                       clear: true, submit: true))
        #expect(report.text == "typed 14 characters into textField (no label) id=email at 201,322 by keyboard, after clearing, then Return  1320ms")
        #expect(report.method == "keyboard" && !report.text.contains("me@example.com"))      // the text may be a secret
    }

    @Test func typingWithoutATargetGoesToTheFocusedElement() async throws {
        defer { base.worktree.remove() }
        var result = ActionResult(element: nil, x: nil, y: nil, ms: 900)
        result.method = "paste"
        var (service, ctx, sent) = try setup(result)
        #expect(try await service.type("a", TypeOptions(into: nil, clear: false, submit: false), options, in: &ctx).text
                == "typed 1 character into the focused element by paste  900ms")
        #expect(try sent.last(as: TypeRequest.self).request.into == nil)
        #expect(try await service.type("", TypeOptions(into: nil, clear: false, submit: true), options, in: &ctx).text
                == "typed 0 characters into the focused element by paste, then Return  900ms")
    }

    @Test func typingThatCannotBeSentIsAUsageError() async throws {
        defer { base.worktree.remove() }
        var (service, ctx, sent) = try setup(ActionResult(element: nil, x: nil, y: nil, ms: 0))
        let plain = TypeOptions(into: nil, clear: false, submit: false)
        let nothing = await #expect(throws: XcdError.self) { _ = try await service.type("", plain, options, in: &ctx) }
        #expect(nothing?.code == .usage && nothing?.message == "there is nothing to type")
        let long = await #expect(throws: XcdError.self) { _ = try await service.type(String(repeating: "a", count: 2001), plain, options, in: &ctx) }
        #expect(long?.code == .usage && long?.message == "the text is 2001 characters; one `xcd ui type` takes at most 2000")
        let point = await #expect(throws: XcdError.self) {
            _ = try await service.type("a", TypeOptions(into: "@1,2", clear: false, submit: false), options, in: &ctx)
        }
        #expect(point?.code == .usage && point?.message == "--into takes an element, not a point")
        #expect(sent.count == 0)
        _ = try await service.type(String(repeating: "a", count: 2000), plain, options, in: &ctx)
        #expect(sent.count == 1)
    }

    /// Typing is slow, so the request is given time in proportion to the text: a request that times out would make
    /// xcd restart a runner that is still typing.
    @Test func aLongTextGetsALongerRequestTimeout() async throws {
        defer { base.worktree.remove() }
        var (service, ctx, transport, _) = try base.setup { _, _ in
            FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.success(ActionResult(element: nil, x: nil, y: nil, ms: 0)))
        }
        let plain = TypeOptions(into: nil, clear: false, submit: false)
        _ = try await service.type("hi", plain, options, in: &ctx)
        #expect(transport.timeouts.last == .seconds(2) + .seconds(30) + .milliseconds(500))
        _ = try await service.type(String(repeating: "a", count: 2000), plain, options, in: &ctx)
        #expect(transport.timeouts.last == .seconds(532))
        _ = try await service.tap("@1,2", options, in: &ctx)
        #expect(transport.timeouts.last == .seconds(32))
    }

    @Test func typingWithNothingFocusedSaysSo() async throws {
        defer { base.worktree.remove() }
        var (service, ctx, _, _) = try base.setup { _, _ in
            FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.failure(RunnerFailure(
                code: RunnerFailure.Code.internal, message: "XCTest reported a problem",
                issues: ["Failed to synthesize event: Neither element nor any descendant has keyboard focus."])))
        }
        let error = await #expect(throws: XcdError.self) {
            _ = try await service.type("a", TypeOptions(into: nil, clear: false, submit: false), options, in: &ctx)
        }
        #expect(error?.code == .elementNotFound && error?.message == "nothing has keyboard focus, so there was nowhere to type")
        #expect(error?.next == "focus a field first: pass `--into <target>`, or tap it")
    }}
