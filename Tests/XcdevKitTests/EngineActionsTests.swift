import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// What the actions share: the keyboard's area, the tree after an action, and an app that an action ended.
@Suite struct EngineActionsTests {
    static let screen = TreeBuilderTests.screen
    static let bundle = "dev.xcdev.SampleApp"

    static func node(_ type: Int, id: String = "", label: String = "", _ frame: ScreenRect, _ children: [SnapshotNode] = []) -> SnapshotNode {
        TreeBuilderTests.node(type, id: id, label: label, frame: frame, children)
    }

    /// The form's own window, as a real app reports it (seen on iOS 27.0).
    static let form = node(4, screen, [node(1, screen, [
        TreeBuilderTests.node(49, id: "email", value: "Email", placeholder: "Email", frame: ScreenRect(x: 32, y: 164, w: 338, h: 22)),
        node(9, id: "signIn", label: "Sign In", ScreenRect(x: 16, y: 288, w: 370, h: 52)),
        node(9, id: "low", label: "Low", ScreenRect(x: 16, y: 560, w: 370, h: 20)),
        node(9, id: "far", label: "Far away", ScreenRect(x: 16, y: 3574, w: 370, h: 52)),
    ])])

    /// The two windows iOS adds while the keyboard is up: a placeholder (`inputView`), and the keyboard with a bar
    /// above its keys and a row of buttons below them.
    static let keyboardWindows = [
        node(4, screen, [node(1, screen, [node(1, ScreenRect(x: 0, y: 546, w: 402, h: 328), [
            node(1, id: "inputView", ScreenRect(x: 0, y: 546, w: 402, h: 328)),
        ])])]),
        node(4, screen, [node(1, screen, [node(1, ScreenRect(x: 0, y: 546, w: 402, h: 328), [
            node(1, id: "SystemInputAssistantView", ScreenRect(x: 0, y: 546, w: 402, h: 44), [node(9, ScreenRect(x: 0, y: 546, w: 134, h: 44))]),
            node(1, ScreenRect(x: 0, y: 590, w: 402, h: 226), [
                node(19, ScreenRect(x: 0, y: 590, w: 402, h: 226), [node(20, label: "Q", ScreenRect(x: 4.7, y: 597, w: 39.3, h: 54))]),
            ]),
            node(1, ScreenRect(x: 0, y: 590, w: 402, h: 284), [node(9, label: "Emoji", ScreenRect(x: 8.5, y: 805.7, w: 68, h: 68.7))]),
        ])])]),
    ]

    static let app = node(2, label: "SampleApp", screen, [form])
    static let appWithKeyboard = node(2, label: "SampleApp", screen, [form] + keyboardWindows)

    func make(_ app: SnapshotNode = app) -> (RunnerEngine, FakeDevice) {
        let device = FakeDevice(app: app, system: RunnerEngineTests.home)
        return (RunnerEngine(device: device), device)
    }

    func request(_ target: TargetSpec, timeout: Double = 2, tree: Bool = false) -> TargetRequest {
        var request = TargetRequest(bundleId: Self.bundle, system: false, target: target, role: nil, index: nil, timeout: timeout, gone: false)
        request.tree = tree
        return request
    }

    @Test func theKeyboardsBarsAreHiddenAndCoverWhatIsUnderThem() throws {
        let (engine, device) = make(Self.appWithKeyboard)
        let tree = try engine.tree(TreeRequest(bundleId: Self.bundle, system: false, all: false)).get()
        #expect(tree.keyboard && tree.elements.map(\.identifier) == ["email", "signIn", "low"])
        // "low" is above the keys but under the bar over them.
        guard case .failure(let covered) = engine.tap(request(.id("low"), timeout: 0.3)) else { Issue.record("tapped"); return }
        #expect(covered.code == RunnerFailure.Code.notHittable && covered.message == "the element is covered by the keyboard")
        _ = try engine.tap(request(.id("signIn"))).get()
        #expect(device.events == ["tap 201,314"])
        // Without the keyboard nothing covers it.
        device.app = Self.app
        _ = try engine.tap(request(.id("low"))).get()
        #expect(device.events.last == "tap 201,570")
    }

    @Test func aFailedSnapshotAtTheDeadlineKeepsTheLastRealAnswer() {
        let (engine, device) = make()
        device.onPause = { if $0.pauses == 1 { $0.failSnapshots = true } }
        guard case .failure(let failure) = engine.tap(request(.id("never"), timeout: 0.5)) else { Issue.record("tapped"); return }
        #expect(failure.code == RunnerFailure.Code.notFound && failure.seen.contains("Sign In") && device.pauses >= 4)
    }

    @Test func anActionSendsTheTreeBackOnlyWhenAsked() throws {
        let (engine, device) = make()
        #expect(try engine.tap(request(.id("signIn"))).get().tree == nil)
        #expect(device.pauses == 0 && engine.refs.isEmpty)
        let result = try engine.tap(request(.id("signIn"), tree: true)).get()
        #expect(result.tree?.elements.map(\.ref) == ["e1", "e2", "e3"] && result.tree?.state == "foreground")
        #expect(device.pauses == 1 && device.clock == 0.3)                 // the effect had time to show
        #expect(engine.refs.keys.sorted() == ["e1", "e2", "e3"])           // the newest tree's refs
        _ = try engine.tap(request(.ref("e2"))).get()
        #expect(device.events.last == "tap 201,314")
    }

    @Test func theTreeIsLeftOutWhenItCannotBeReadAfterTheAction() throws {
        let (engine, device) = make()
        device.onGesture = { $0.failSnapshots = true }
        let result = try engine.tap(request(.id("signIn"), tree: true)).get()
        #expect(result.tree == nil && result.element?.identifier == "signIn" && device.pauses == 5)
    }

    @Test func anActionThatEndsTheAppIsACrash() {
        let (engine, device) = make()
        device.onGesture = { $0.state = .notRunning }
        guard case .failure(let crash) = engine.tap(request(.id("signIn"), tree: true)) else { Issue.record("no failure"); return }
        #expect(crash.code == RunnerFailure.Code.appCrashed && crash.message == "the app is no longer running after the tap")
        #expect(device.events == ["tap 201,314"] && device.pauses == 0)    // tapped once; no tree is read
        // An app that only went to the background was not ended.
        device.state = .foreground
        device.onGesture = { $0.state = .background }
        #expect((try? engine.tap(request(.id("signIn"))).get()) != nil)
    }

    @Test func aPointTapWhileTheAppIsNotRunningIsNotACrash() throws {
        let (engine, device) = make()
        device.state = .notRunning
        #expect(try engine.tap(request(.point(x: 10, y: 20))).get().x == 10)
        device.state = .foreground
        device.onGesture = { $0.state = .notRunning }
        guard case .failure(let crash) = engine.tap(request(.point(x: 10, y: 20))) else { Issue.record("no failure"); return }
        #expect(crash.code == RunnerFailure.Code.appCrashed)
        // The system has no app to lose.
        let home = TargetRequest(bundleId: nil, system: true, target: .label("Settings"), role: nil, index: nil, timeout: 1, gone: false)
        #expect(try engine.tap(home).get().element?.label == "Settings")
    }

    @Test func aGestureThatThrowsIsReportedAndNotRepeated() {
        let (engine, device) = make()
        device.failGestures = true
        guard case .failure(let failure) = engine.tap(request(.id("signIn"), timeout: 1)) else { Issue.record("tapped"); return }
        #expect(failure.code == RunnerFailure.Code.internal && failure.message == "the tap failed: gesture failed" && device.pauses == 0)
    }
}

@Suite struct EngineGestureTests {
    let base = EngineActionsTests()

    func swipe(_ direction: SwipeDirection?, on: TargetSpec? = nil, from: ScreenPoint? = nil, to: ScreenPoint? = nil,
               timeout: Double = 1) -> SwipeRequest {
        SwipeRequest(scope: ActionScope(bundleId: EngineActionsTests.bundle, system: false, timeout: timeout, tree: false), direction: direction,
                     on: on.map { ElementQuery(target: $0, role: nil, index: nil) }, from: from, to: to)
    }

    @Test func aLongPressHoldsTheElementsCentre() throws {
        let (engine, device) = base.make()
        var request = base.request(.id("signIn"))
        let result = try engine.longPress(request).get()
        #expect(device.events == ["press 201,314 1.0s"] && result.element?.identifier == "signIn" && result.x == 201 && result.y == 314)
        request.duration = 2.5
        _ = try engine.longPress(request).get()
        for (asked, held) in [(0.0, "0.1"), (1e9, "60.0"), (Double.nan, "1.0")] {
            request.duration = asked
            _ = try engine.longPress(request).get()
            #expect(device.events.last == "press 201,314 \(held)s")
        }
        #expect(device.events[1] == "press 201,314 2.5s")
        _ = try engine.longPress(base.request(.point(x: 5, y: 6))).get()
        #expect(device.events.last == "press 5,6 1.0s")
        guard case .failure(let missing) = engine.longPress(base.request(.id("nope"), timeout: 0.2)) else { Issue.record("pressed"); return }
        #expect(missing.code == RunnerFailure.Code.notFound && device.events.count == 6)
    }

    @Test func aDirectionSwipeGoesFromTheCentreAcrossTwoFifthsOfTheElement() throws {
        let (engine, device) = base.make()
        let result = try engine.swipe(swipe(.up, on: .id("signIn"))).get()         // 16,288 370x52
        #expect(device.events == ["drag 201,314 to 201,293.2 0.3s"])
        #expect(result.element?.identifier == "signIn" && result.x == 201 && result.y == 314 && result.toX == 201 && result.toY == 293.2)
        _ = try engine.swipe(swipe(.right, on: .id("signIn"))).get()
        #expect(device.events.last == "drag 201,314 to 349,314 0.3s")
        // With no element: across the screen (402x874).
        let across = try engine.swipe(swipe(.up)).get()
        #expect(device.events.last == "drag 201,437 to 201,87.4 0.3s" && across.element == nil && abs((across.toY ?? 0) - 87.4) < 0.001)
        _ = try engine.swipe(swipe(.down)).get()
        #expect(device.events.last == "drag 201,437 to 201,786.6 0.3s")
        _ = try engine.swipe(swipe(.left)).get()
        #expect(device.events.last == "drag 201,437 to 40.2,437 0.3s")
    }

    @Test func aSwipeBetweenTwoPointsHappensWhateverIsOnScreen() throws {
        let (engine, device) = base.make()
        device.state = .background
        let result = try engine.swipe(swipe(nil, from: ScreenPoint(x: 10, y: 600), to: ScreenPoint(x: 10, y: 100))).get()
        #expect(device.events == ["drag 10,600 to 10,100 0.3s"] && result.x == 10 && result.y == 600 && result.toY == 100 && device.pauses == 0)
        // A direction needs the app in front: its extent decides how far the swipe goes.
        guard case .failure(let away) = engine.swipe(swipe(.up, timeout: 0.3)) else { Issue.record("swiped"); return }
        #expect(away.code == RunnerFailure.Code.appNotForeground && device.events.count == 1 && device.pauses >= 2)
    }

    @Test func aSwipeNeedsADirectionOrBothPoints() {
        let (engine, device) = base.make()
        let point = ScreenPoint(x: 1, y: 2)
        for bad in [swipe(nil), swipe(nil, from: point), swipe(.up, from: point, to: point), swipe(nil, on: .id("signIn"), from: point, to: point)] {
            guard case .failure(let failure) = engine.swipe(bad) else { Issue.record("swiped"); continue }
            #expect(failure.code == RunnerFailure.Code.badRequest)
        }
        guard case .failure(let off) = engine.swipe(swipe(.up, on: .id("far"), timeout: 0.2)) else { Issue.record("swiped"); return }
        #expect(off.code == RunnerFailure.Code.notHittable && device.events.isEmpty)
    }

    @Test func gesturesAreServedOverHTTP() throws {
        let (engine, device) = base.make()
        var press = base.request(.id("signIn"))
        press.duration = 2
        let pressed = try JSONDecoder().decode(RunnerReply<ActionResult>.self,
                                               from: engine.handle(path: "/longpress", body: try JSONEncoder().encode(press)))
        #expect(pressed.ok && device.events == ["press 201,314 2.0s"])
        let swiped = try JSONDecoder().decode(RunnerReply<ActionResult>.self,
                                              from: engine.handle(path: "/swipe", body: try JSONEncoder().encode(swipe(.up))))
        #expect(swiped.ok && abs((swiped.result?.toY ?? 0) - 87.4) < 0.001)
        let bad = try JSONDecoder().decode(RunnerReply<ActionResult>.self, from: engine.handle(path: "/swipe", body: Data("{}".utf8)))
        #expect(!bad.ok && bad.failure?.code == RunnerFailure.Code.badRequest)
    }
}

@Suite struct EngineTypingTests {
    let base = EngineActionsTests()

    func type(_ text: String, into: TargetSpec? = .id("email"), clear: Bool = false, submit: Bool = false, tree: Bool = false) -> TypeRequest {
        TypeRequest(scope: ActionScope(bundleId: EngineActionsTests.bundle, system: false, timeout: 1, tree: tree), text: text,
                    into: into.map { ElementQuery(target: $0, role: nil, index: nil) }, clear: clear, submit: submit)
    }

    /// A device whose keyboard comes up when something is tapped.
    func make() -> (RunnerEngine, FakeDevice) {
        let (engine, device) = base.make()
        device.onGesture = { device in
            if device.events.last?.hasPrefix("tap") == true { device.app = EngineActionsTests.appWithKeyboard }
        }
        return (engine, device)
    }

    @Test func typingIntoAFieldTapsItThenTypes() throws {
        let (engine, device) = make()
        let result = try engine.enterText(type("me@example.com")).get()
        #expect(device.events == ["tap 201,175", "type \"me@example.com\""])
        #expect(result.method == "keyboard" && result.element?.identifier == "email" && result.x == 201 && result.y == 175)
        #expect(device.pauses == 0 && device.pasteboardText == nil)
    }

    @Test func clearSelectsEverythingAndSubmitPressesReturn() throws {
        let (engine, device) = make()
        _ = try engine.enterText(type("new", clear: true, submit: true)).get()
        #expect(device.events == ["tap 201,175", "key cmd-\"a\"", "type " + "\u{8}new\n".debugDescription])
        // Clearing alone deletes the selection.
        _ = try engine.enterText(type("", clear: true)).get()
        #expect(device.events.suffix(2) == ["key cmd-\"a\"", "type " + "\u{8}".debugDescription])
        // Nothing to type is nothing typed.
        let before = device.events.count
        _ = try engine.enterText(type("", into: nil)).get()
        #expect(device.events.count == before)
    }

    @Test func withoutATargetItTypesIntoWhateverHasFocus() throws {
        let (engine, device) = base.make(EngineActionsTests.appWithKeyboard)
        let result = try engine.enterText(type("hi", into: nil)).get()
        #expect(device.events == ["type \"hi\""] && result.element == nil && result.x == nil && result.method == "keyboard")
    }

    @Test func withNoKeyboardTheTextIsPastedAndTypeTextIsNeverCalled() throws {
        let (engine, device) = base.make()                                  // tapping brings up no keyboard
        let result = try engine.enterText(type("hi")).get()
        #expect(device.events == ["tap 201,175", "pasteboard \"hi\"", "key cmd-\"v\""])
        #expect(result.method == "paste" && device.pauses >= 14)            // waited 1.5 s for a keyboard first
        device.events = []
        _ = try engine.enterText(type("", clear: true, submit: true)).get()
        #expect(device.events == ["tap 201,175", "key cmd-\"a\"", "key " + "\u{8}".debugDescription, "key " + "\r".debugDescription])
        device.events = []
        _ = try engine.enterText(type("x", clear: true, submit: true)).get()
        #expect(device.events == ["tap 201,175", "key cmd-\"a\"", "pasteboard \"x\"", "key cmd-\"v\"", "key " + "\r".debugDescription])
        #expect(!device.events.contains { $0.hasPrefix("type") })
    }

    /// `node` and everything under it as a device that can tell reports them: only the element `id` has keyboard focus.
    static func reportingFocus(on id: String?, _ node: SnapshotNode) -> SnapshotNode {
        var node = node
        node.focused = id != nil && node.identifier == id
        node.children = node.children.map { reportingFocus(on: id, $0) }
        return node
    }

    /// Seen on iOS 27.0: a paste with nothing focused goes nowhere and XCTest reports no problem, so it would
    /// pass for typing that worked. The device's pasteboard is left alone too.
    @Test func withNoKeyboardAndNothingFocusedThereIsNowhereToType() throws {
        let (engine, device) = base.make(Self.reportingFocus(on: nil, EngineActionsTests.app))
        for request in [type("hi", into: nil), type("", into: nil, clear: true), type("", into: nil, submit: true)] {
            guard case .failure(let failure) = engine.enterText(request) else { Issue.record("typed"); return }
            #expect(failure.code == RunnerFailure.Code.nothingFocused && failure.message == "nothing has keyboard focus")
        }
        #expect(device.events.isEmpty && device.pasteboardText == nil && device.pauses >= 14)      // it looked for 1.5 s first
        // A tap that gives nothing focus (the target is not a field) ends the same way, after the tap.
        guard case .failure(let failure) = engine.enterText(type("hi", into: .id("signIn"))) else { Issue.record("typed"); return }
        #expect(failure.code == RunnerFailure.Code.nothingFocused && device.events == ["tap 201,314"])
    }

    @Test func withNoKeyboardTheTextIsPastedIntoTheFieldThatHasFocus() throws {
        let (engine, device) = base.make(Self.reportingFocus(on: nil, EngineActionsTests.app))
        device.onGesture = { device in                                      // the tap gives the field focus; no keyboard comes up
            if device.events.last == "tap 201,175" { device.app = Self.reportingFocus(on: "email", EngineActionsTests.app) }
        }
        let result = try engine.enterText(type("hi")).get()
        #expect(device.events == ["tap 201,175", "pasteboard \"hi\"", "key cmd-\"v\""] && result.method == "paste")
        // Focus that came from an earlier tap counts too.
        #expect(try engine.enterText(type("more", into: nil)).get().method == "paste")
        #expect(device.events.suffix(2) == ["pasteboard \"more\"", "key cmd-\"v\""])
    }

    /// The keyboard is proof enough: what it types into is not looked for.
    @Test func withAKeyboardUpFocusIsNotAsked() throws {
        let (engine, device) = base.make(Self.reportingFocus(on: nil, EngineActionsTests.appWithKeyboard))
        #expect(try engine.enterText(type("hi", into: nil)).get().method == "keyboard" && device.events == ["type \"hi\""])
    }

    @Test func theKeyboardTipCardIsDismissedFirst() throws {
        let card = EngineActionsTests.node(1, ScreenRect(x: 0, y: 546, w: 402, h: 328), [
            EngineActionsTests.node(48, label: "Speed up your typing by sliding your finger across the letters to compose a word.",
                                    ScreenRect(x: 20, y: 600, w: 362, h: 60)),
            EngineActionsTests.node(9, label: "Continue", ScreenRect(x: 101, y: 780, w: 200, h: 44)),
        ])
        let withCard = EngineActionsTests.node(2, label: "SampleApp", EngineActionsTests.screen,
                                               [EngineActionsTests.form] + EngineActionsTests.keyboardWindows + [EngineActionsTests.node(4, EngineActionsTests.screen, [card])])
        let (engine, device) = base.make(withCard)
        device.onGesture = { device in
            if device.events.last == "tap 201,802" { device.app = EngineActionsTests.appWithKeyboard }
        }
        _ = try engine.enterText(type("hi", into: nil)).get()
        #expect(device.events == ["tap 201,802", "type \"hi\""])
    }

    @Test func typingNeedsTheAppInFrontAndItsField() {
        let (engine, device) = make()
        guard case .failure(let missing) = engine.enterText(type("x", into: .id("nope"))) else { Issue.record("typed"); return }
        #expect(missing.code == RunnerFailure.Code.notFound && device.events.isEmpty)
        device.state = .background
        guard case .failure(let away) = engine.enterText(type("x", into: nil)) else { Issue.record("typed"); return }
        #expect(away.code == RunnerFailure.Code.appNotForeground && device.events.isEmpty)
        let nowhere = TypeRequest(scope: ActionScope(bundleId: nil, system: false, timeout: 1, tree: false), text: "x", into: nil, clear: false, submit: false)
        guard case .failure(let refused) = engine.enterText(nowhere) else { Issue.record("typed"); return }
        #expect(refused.code == RunnerFailure.Code.badRequest)
    }

    @Test func aTypingFailureIsReportedAndTheTreeComesBackWhenAsked() throws {
        let (engine, device) = base.make(EngineActionsTests.appWithKeyboard)
        let result = try engine.enterText(type("hi", into: nil, tree: true)).get()
        #expect(result.tree?.keyboard == true && result.tree?.elements.map(\.identifier) == ["email", "signIn", "low"])
        device.failGestures = true
        guard case .failure(let failure) = engine.enterText(type("hi", into: nil)) else { Issue.record("typed"); return }
        #expect(failure.code == RunnerFailure.Code.internal && failure.message == "the typing failed: gesture failed")
        device.failGestures = false
        let body = try JSONEncoder().encode(type("via http", into: nil))
        let reply = try JSONDecoder().decode(RunnerReply<ActionResult>.self, from: engine.handle(path: "/type", body: body))
        #expect(reply.ok && reply.result?.method == "keyboard" && device.events.last == "type \"via http\"")
    }
}

@Suite struct EngineDeviceTests {
    let base = EngineActionsTests()

    func request(_ name: String, tree: Bool = false, system: Bool = false) -> DeviceRequest {
        DeviceRequest(scope: ActionScope(bundleId: system ? nil : EngineActionsTests.bundle, system: system, timeout: 2, tree: tree), name: name)
    }

    @Test func aButtonThisDeviceHasIsPressed() throws {
        let (engine, device) = base.make()
        device.onGesture = { $0.state = .background }                       // Home sends the app to the background
        let result = try engine.button(request("home", tree: true)).get()
        #expect(device.events == ["button home"] && result.element == nil && result.x == nil)
        #expect(result.tree?.state == "background")                         // not a crash; the tree shows Springboard
        guard case .failure(let missing) = engine.button(request("action")) else { Issue.record("pressed"); return }
        #expect(missing.code == RunnerFailure.Code.unsupported && missing.message == "this device has no action button")
        guard case .failure(let unknown) = engine.button(request("volume-up")) else { Issue.record("pressed"); return }
        #expect(unknown.code == RunnerFailure.Code.badRequest && unknown.message == "'volume-up' is not a button; use one of: home, action, camera")
        #expect(device.events.count == 1)
        device.buttons = [.home, .camera]
        _ = try engine.button(request("camera", system: true)).get()
        #expect(device.events.last == "button camera")
    }

    /// Nothing happened, so there is nothing to settle or read: the refs of the last tree stay as they were.
    @Test func aButtonThisDeviceLacksEndsTheActionBeforeAnyTreeIsRead() throws {
        let (engine, device) = base.make()
        guard case .failure(let missing) = engine.button(request("action", tree: true)) else { Issue.record("pressed"); return }
        #expect(missing.code == RunnerFailure.Code.unsupported && missing.message == "this device has no action button")
        #expect(device.snapshots == 0 && device.pauses == 0 && device.events.isEmpty)
        device.state = .notRunning                                          // nor is a missing app taken for a crash
        guard case .failure(let still) = engine.button(request("camera", tree: true)) else { Issue.record("pressed"); return }
        #expect(still.code == RunnerFailure.Code.unsupported && device.snapshots == 0)
    }

    /// On a real device the app is still in front for a moment after Home is pressed.
    @Test func homeWaitsForTheAppToLeaveTheScreen() throws {
        let (engine, device) = base.make()
        device.onPause = { if $0.pauses == 3 { $0.state = .background } }
        let result = try engine.button(request("home", tree: true)).get()
        #expect(result.tree?.state == "background" && device.pauses == 4)   // three waiting, one before the tree
        // An app that never leaves is not waited for beyond two seconds, and another button is not waited for at all.
        device.onPause = nil
        device.state = .foreground
        device.pauses = 0
        #expect(try engine.button(request("home")).get().tree == nil)
        #expect(device.pauses == 20)
        device.buttons = [.home, .action]
        device.pauses = 0
        _ = try engine.button(request("action")).get()
        #expect(device.pauses == 0)
    }

    @Test func rotatingChangesTheOrientationTheTreeReports() throws {
        let (engine, device) = base.make()
        let result = try engine.rotate(request("landscape-left", tree: true)).get()
        #expect(device.events == ["rotate landscape-left"] && result.tree?.orientation == "landscape-left")
        guard case .failure(let unknown) = engine.rotate(request("sideways")) else { Issue.record("rotated"); return }
        #expect(unknown.code == RunnerFailure.Code.badRequest)
        #expect(unknown.message == "'sideways' is not an orientation; use one of: portrait, portrait-upside-down, landscape-left, landscape-right")
        let nowhere = DeviceRequest(scope: ActionScope(bundleId: nil, system: false, timeout: 1, tree: false), name: "portrait")
        guard case .failure(let refused) = engine.rotate(nowhere) else { Issue.record("rotated"); return }
        #expect(refused.code == RunnerFailure.Code.badRequest && device.events.count == 1)
    }

    @Test func buttonsAndRotationAreServedOverHTTP() throws {
        let (engine, device) = base.make()
        for (path, name) in [("/button", "home"), ("/rotate", "portrait-upside-down")] {
            let reply = try JSONDecoder().decode(RunnerReply<ActionResult>.self,
                                                 from: engine.handle(path: path, body: try JSONEncoder().encode(request(name))))
            #expect(reply.ok, "\(path)")
        }
        #expect(device.events == ["button home", "rotate portrait-upside-down"])
    }

    @Test func anImageGoesOnThePasteboard() throws {
        let (engine, device) = base.make()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        #expect(try engine.pasteboard(PasteboardRequest(image: png)).get().hasImages)
        #expect(device.events == ["pasteboard image 11 bytes"])
        guard case .failure(let bad) = engine.pasteboard(PasteboardRequest(image: Data("not an image".utf8))) else { Issue.record("set"); return }
        #expect(bad.code == RunnerFailure.Code.badRequest && bad.message == "the data is not an image iOS can read")
        let body = try JSONEncoder().encode(PasteboardRequest(image: png))
        let reply = try JSONDecoder().decode(RunnerReply<PasteboardResult>.self, from: engine.handle(path: "/pasteboard", body: body))
        #expect(reply.ok && reply.result?.hasImages == true && device.events.count == 2)
    }
}
