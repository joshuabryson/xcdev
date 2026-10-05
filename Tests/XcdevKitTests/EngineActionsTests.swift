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
