import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct RunnerEngineTests {
    static let screen = TreeBuilderTests.screen
    static let home = TreeBuilderTests.node(2, label: "Springboard", frame: screen, [
        TreeBuilderTests.node(4, frame: screen, [TreeBuilderTests.node(44, label: "Settings", frame: ScreenRect(x: 30, y: 100, w: 60, h: 60))]),
    ])
    static let alert = TreeBuilderTests.node(7, label: "Allow Photos?", frame: ScreenRect(x: 41, y: 325, w: 320, h: 252), [
        TreeBuilderTests.node(9, label: "Allow", frame: ScreenRect(x: 57, y: 457, w: 288, h: 48)),
    ])

    /// The sample app without its keyboard, so taps on the lower half are not covered.
    static let appWithoutKeyboard = TreeBuilderTests.node(2, label: "SampleApp", frame: screen, [
        TreeBuilderTests.node(4, frame: screen, [
            TreeBuilderTests.node(1, frame: screen, [
                TreeBuilderTests.node(9, id: "signIn", label: "Sign In", frame: ScreenRect(x: 24, y: 700, w: 354, h: 50)),
                TreeBuilderTests.node(9, id: "far", label: "Far away", frame: ScreenRect(x: 24, y: 3574, w: 100, h: 44)),
            ]),
        ]),
    ])

    func make(_ device: FakeDevice = FakeDevice(app: TreeBuilderTests.app, system: home)) -> (RunnerEngine, FakeDevice) {
        (RunnerEngine(device: device), device)
    }

    func request(_ target: TargetSpec, timeout: Double = 2, gone: Bool = false, role: String? = nil, index: Int? = nil) -> TargetRequest {
        TargetRequest(bundleId: "dev.xcdev.SampleApp", system: false, target: target, role: role, index: index, timeout: timeout, gone: gone)
    }

    @Test func theTreeShowsTheAppItsStateAndFreshRefs() throws {
        let (engine, _) = make()
        let tree = try engine.tree(TreeRequest(bundleId: "dev.xcdev.SampleApp", system: false, all: false)).get()
        #expect(tree.state == "foreground" && tree.bundleId == "dev.xcdev.SampleApp")
        #expect(tree.screen == Self.screen && tree.scale == 3 && tree.orientation == "portrait" && tree.keyboard)
        #expect(tree.elements.map(\.ref) == ["e1", "e2", "e3", "e4"])
        #expect(tree.elements.map(\.identifier) == ["signIn", "email", "", ""])
        #expect(engine.refs.keys.sorted() == ["e1", "e2", "e3", "e4"])
        #expect(try engine.tree(TreeRequest(bundleId: "dev.xcdev.SampleApp", system: false, all: true)).get().elements.count == 11)
    }

    @Test func aSystemAlertIsAppendedAndABackgroundAppShowsSpringboard() throws {
        let (engine, device) = make()
        device.alert = Self.alert
        let withAlert = try engine.tree(TreeRequest(bundleId: "b", system: false, all: false)).get()
        #expect(withAlert.elements.suffix(2).map(\.label) == ["Allow Photos?", "Allow"])
        #expect(withAlert.elements.suffix(2).allSatisfy { $0.source == .system })
        device.state = .background
        let background = try engine.tree(TreeRequest(bundleId: "b", system: false, all: false)).get()
        #expect(background.state == "background" && background.elements.map(\.label) == ["Settings"])
        #expect(background.elements.allSatisfy { $0.source == .system })
        device.state = .notRunning
        #expect(try engine.tree(TreeRequest(bundleId: "b", system: false, all: false)).get().state == "not_running")
        #expect(try engine.tree(TreeRequest(bundleId: nil, system: true, all: false)).get().state == "system")
    }

    @Test func tapsTheCentreOfTheMatchedElement() throws {
        let (engine, device) = make(FakeDevice(app: Self.appWithoutKeyboard, system: Self.home))
        let result = try engine.tap(request(.id("signIn"))).get()
        #expect(device.taps.count == 1 && device.taps[0].x == 201 && device.taps[0].y == 725)
        #expect(result.element?.identifier == "signIn" && result.x == 201 && result.y == 725)
        _ = try engine.tap(request(.point(x: 10, y: 20))).get()
        #expect(device.taps.last?.x == 10 && device.taps.last?.y == 20)
        device.alert = Self.alert
        _ = try engine.tap(request(.label("Allow"))).get()                 // an element of the system alert
        #expect(device.taps.last?.x == 201 && device.taps.last?.y == 481)
    }

    @Test func aRefFromTheLastTreeTaps() throws {
        let (engine, device) = make()
        _ = engine.tree(TreeRequest(bundleId: "b", system: false, all: false))
        _ = try engine.tap(request(.ref("e4"))).get()                      // the unlabelled icon button
        #expect(device.taps[0].x == 372 && device.taps[0].y == 82)
        guard case .failure(let stale) = engine.tap(request(.ref("e77"))) else { Issue.record("tapped"); return }
        #expect(stale.code == RunnerFailure.Code.staleRef && device.taps.count == 1)
    }

    @Test func aMissingElementIsPolledForUntilTheTimeout() {
        let (engine, device) = make()
        guard case .failure(let failure) = engine.tap(request(.id("later"), timeout: 1)) else { Issue.record("tapped"); return }
        #expect(failure.code == RunnerFailure.Code.notFound && device.pauses >= 9 && device.taps.isEmpty)
        #expect(failure.seen.contains("Sign In") && failure.seen.contains("signIn"))

        // It appears on the third poll.
        device.pauses = 0
        device.onPause = { device in
            if device.pauses == 3 {
                device.app = TreeBuilderTests.node(2, frame: Self.screen, [TreeBuilderTests.node(9, id: "later", label: "Later",
                                                   frame: ScreenRect(x: 0, y: 0, w: 100, h: 40))])
            }
        }
        #expect((try? engine.tap(request(.id("later"), timeout: 1)).get())?.element?.identifier == "later")
        #expect(device.pauses == 3)
    }

    @Test func anOffscreenOrDisabledMatchIsNotTapped() {
        let (engine, device) = make()
        guard case .failure(let off) = engine.tap(request(.id("far"), timeout: 0.3)) else { Issue.record("tapped"); return }
        #expect(off.code == RunnerFailure.Code.notHittable && off.frame?.y == 3574 && off.message.contains("off screen"))
        device.app = TreeBuilderTests.node(2, frame: Self.screen, [TreeBuilderTests.node(9, id: "off", label: "Off", enabled: false)])
        guard case .failure(let disabled) = engine.tap(request(.id("off"), timeout: 0.3)) else { Issue.record("tapped"); return }
        #expect(disabled.code == RunnerFailure.Code.notHittable && disabled.message.contains("disabled") && device.taps.isEmpty)
    }

    @Test func anAmbiguousTargetListsItsCandidatesWithRefs() throws {
        let row = { (y: Double) in TreeBuilderTests.node(9, label: "Delete", frame: ScreenRect(x: 0, y: y, w: 100, h: 40)) }
        let (engine, device) = make(FakeDevice(app: TreeBuilderTests.node(2, frame: Self.screen, [row(100), row(200), row(5000)]), system: Self.home))
        guard case .failure(let failure) = engine.tap(request(.label("Delete"))) else { Issue.record("tapped"); return }
        #expect(failure.code == RunnerFailure.Code.ambiguous && failure.candidates.map(\.ref) == ["e1", "e2", "e3"])
        #expect(device.taps.isEmpty && device.pauses == 0)                 // no polling: waiting won't make it unique
        #expect(engine.refs.count == 3)                                    // exactly the candidates, off-screen one included
        _ = try engine.tap(request(.ref("e2"))).get()
        #expect(device.taps.count == 1 && device.taps[0].x == 50 && device.taps[0].y == 220)
    }

    @Test func identicalCandidatesGetTheirOwnRefs() throws {
        let row = TreeBuilderTests.node(9, label: "Delete", frame: ScreenRect(x: 0, y: 100, w: 100, h: 40))
        let (engine, _) = make(FakeDevice(app: TreeBuilderTests.node(2, frame: Self.screen, [row, row]), system: Self.home))
        guard case .failure(let failure) = engine.tap(request(.label("Delete"))) else { Issue.record("tapped"); return }
        #expect(failure.candidates.map(\.ref) == ["e1", "e2"] && engine.refs.count == 2 && Set(engine.refs.values).count == 2)
    }

    @Test func tapAndWaitIgnoreSpringboardWhenTheAppIsNotInFront() {
        let (engine, device) = make()
        device.state = .notRunning
        guard case .failure(let crashed) = engine.tap(request(.label("Settings"), timeout: 0.5)) else { Issue.record("tapped"); return }
        #expect(crashed.code == RunnerFailure.Code.appNotForeground && crashed.message.contains("not running") && device.taps.isEmpty)
        #expect(device.pauses >= 4)                                         // kept polling: the app may be coming forward
        device.state = .background
        guard case .failure(let away) = engine.wait(request(.id("signIn"), timeout: 0.3, gone: true)) else { Issue.record("met"); return }
        #expect(away.code == RunnerFailure.Code.appNotForeground && away.message.contains("background"))
        guard case .failure(let never) = engine.wait(request(.id("signIn"), timeout: 0.3)) else { Issue.record("met"); return }
        #expect(never.code == RunnerFailure.Code.appNotForeground)
        // The app comes forward on the second poll.
        device.pauses = 0
        device.state = .background
        device.onPause = { $0.state = .foreground }
        #expect((try? engine.wait(request(.id("signIn"), timeout: 1)).get())?.element?.identifier == "signIn")
        // A system target still reads Springboard.
        device.state = .notRunning
        let home = TargetRequest(bundleId: nil, system: true, target: .label("Settings"), role: nil, index: nil, timeout: 1, gone: false)
        #expect((try? engine.tap(home).get())?.element?.label == "Settings")
    }

    @Test func anElementUnderTheKeyboardOrAnAlertIsNotTapped() throws {
        let (engine, device) = make()                                       // signIn's centre is inside the keyboard
        guard case .failure(let keyboard) = engine.tap(request(.id("signIn"), timeout: 0.3)) else { Issue.record("tapped"); return }
        #expect(keyboard.code == RunnerFailure.Code.notHittable && keyboard.message.contains("keyboard") && keyboard.frame?.y == 700)
        #expect(device.taps.isEmpty)
        let under = TreeBuilderTests.node(9, id: "under", label: "Under", frame: ScreenRect(x: 100, y: 400, w: 100, h: 40))
        device.app = TreeBuilderTests.node(2, frame: Self.screen, [under])
        device.alert = Self.alert
        guard case .failure(let covered) = engine.tap(request(.id("under"), timeout: 0.3)) else { Issue.record("tapped"); return }
        #expect(covered.code == RunnerFailure.Code.notHittable && covered.message.contains("system alert") && device.taps.isEmpty)
        _ = try engine.tap(request(.label("Allow"))).get()                  // the alert's own button
        #expect(device.taps.count == 1 && device.taps[0].y == 481)
        // wait is about presence: a covered element is still there.
        #expect(try engine.wait(request(.id("under"))).get().element?.identifier == "under")
    }

    @Test func anElementWithNoSizeIsReportedAsSuch() {
        let (engine, device) = make()
        device.app = TreeBuilderTests.node(2, frame: Self.screen, [
            TreeBuilderTests.node(9, id: "flat", label: "Flat", frame: ScreenRect(x: 10, y: 10, w: 0, h: 0))])
        guard case .failure(let failure) = engine.tap(request(.id("flat"), timeout: 0.2)) else { Issue.record("tapped"); return }
        #expect(failure.code == RunnerFailure.Code.notHittable && failure.message.contains("no size"))
    }

    @Test func aNonFiniteFrameBecomesAnEmptyOne() throws {
        let bad = TreeBuilderTests.node(9, id: "bad", label: "Bad", frame: ScreenRect(x: .infinity, y: .nan, w: -.infinity, h: 40))
        var nodes: [FlatNode] = []
        TreeBuilder.flatten(TreeBuilderTests.node(2, frame: Self.screen, [bad]), source: .app, into: &nodes)
        #expect(nodes[1].frame == ScreenRect(x: 0, y: 0, w: 0, h: 40) && nodes[1].frame.isEmpty)
        let (engine, _) = make(FakeDevice(app: TreeBuilderTests.node(2, frame: Self.screen, [bad]), system: Self.home))
        let tree = try engine.tree(TreeRequest(bundleId: "b", system: false, all: true)).get()
        #expect(tree.elements.count == 2)
        let reply = engine.handle(path: "/tree", body: Data(#"{"bundleId":"b","system":false,"all":true}"#.utf8))
        #expect(try JSONDecoder().decode(RunnerReply<TreeResult>.self, from: reply).ok)
    }

    @Test func theTimeoutIsClamped() {
        let (engine, device) = make()
        _ = engine.tap(request(.id("never"), timeout: 1e9))
        #expect(device.pauses >= 1100 && device.pauses <= 1200)             // 120 s at 0.1 s
        device.pauses = 0
        _ = engine.tap(request(.id("never"), timeout: .nan))
        #expect(device.pauses == 0)
        _ = engine.wait(request(.id("never"), timeout: -5))
        #expect(device.pauses == 0)
    }

    @Test func waitingForAGoneRefAndForAPoint() throws {
        let (engine, _) = make()
        guard case .failure(let unknown) = engine.wait(request(.ref("e9"), timeout: 0.2, gone: true)) else { Issue.record("met"); return }
        #expect(unknown.code == RunnerFailure.Code.staleRef)                // never issued: unknown, not gone
        guard case .failure(let point) = engine.wait(request(.point(x: 1, y: 2))) else { Issue.record("met"); return }
        #expect(point.code == RunnerFailure.Code.badRequest && point.message.contains("point"))
    }

    @Test func aKnownRefWhoseElementWentIsGone() throws {
        let (engine, device) = make()
        _ = try engine.tree(TreeRequest(bundleId: "b", system: false, all: false)).get()
        device.app = TreeBuilderTests.node(2, frame: Self.screen, [])
        #expect(try engine.wait(request(.ref("e1"), gone: true)).get().element == nil)
    }

    @Test func requestsSentThroughHandleRoundTrip() throws {
        let (engine, device) = make(FakeDevice(app: Self.appWithoutKeyboard, system: Self.home))
        func send(_ path: String, _ target: TargetSpec, gone: Bool = false) throws -> Data {
            let body = try JSONEncoder().encode(request(target, timeout: 0.2, gone: gone))
            return engine.handle(path: path, body: body)
        }
        for target in [TargetSpec.id("signIn"), .label("Sign In"), .labelContains("sign")] {
            let reply = try JSONDecoder().decode(RunnerReply<ActionResult>.self, from: send("/tap", target))
            #expect(reply.ok && reply.result?.x == 201 && reply.result?.y == 725)
        }
        let point = try JSONDecoder().decode(RunnerReply<ActionResult>.self, from: send("/tap", .point(x: 5, y: 6)))
        #expect(point.ok && point.result?.x == 5 && device.taps.count == 4)
        _ = try JSONDecoder().decode(RunnerReply<TreeResult>.self, from: engine.handle(path: "/tree", body: Data(#"{"bundleId":"b","system":false,"all":false}"#.utf8)))
        let ref = try JSONDecoder().decode(RunnerReply<ActionResult>.self, from: send("/tap", .ref("e1")))
        #expect(ref.ok)
        let waited = try JSONDecoder().decode(RunnerReply<ActionResult>.self, from: send("/wait", .id("signIn")))
        #expect(waited.ok && waited.result?.element?.identifier == "signIn")
        let missing = try JSONDecoder().decode(RunnerReply<ActionResult>.self, from: send("/wait", .id("nope")))
        #expect(!missing.ok && missing.failure?.code == RunnerFailure.Code.waitTimeout && missing.result == nil)
        let notPoint = try JSONDecoder().decode(RunnerReply<ActionResult>.self, from: send("/wait", .point(x: 1, y: 1)))
        #expect(notPoint.failure?.code == RunnerFailure.Code.badRequest)
    }

    @Test func theEncodeFallbackIsAValidFailureEnvelope() throws {
        let reply = try JSONDecoder().decode(RunnerReply<TreeResult>.self, from: Data(RunnerEngine.encodeFallback.utf8))
        #expect(!reply.ok && reply.failure?.code == RunnerFailure.Code.internal && reply.failure?.message.isEmpty == false)
    }

    @Test func waitReturnsWhenTheElementAppearsOrGoes() throws {
        let (engine, device) = make()
        #expect(try engine.wait(request(.id("signIn"))).get().element?.identifier == "signIn")
        #expect(device.pauses == 0)
        guard case .failure(let timeout) = engine.wait(request(.id("never"), timeout: 0.5)) else { Issue.record("met"); return }
        #expect(timeout.code == RunnerFailure.Code.waitTimeout && !timeout.seen.isEmpty)
        #expect(try engine.wait(request(.id("never"), gone: true)).get().element == nil)          // already gone
        guard case .failure(let stays) = engine.wait(request(.id("signIn"), timeout: 0.5, gone: true)) else { Issue.record("met"); return }
        #expect(stays.code == RunnerFailure.Code.waitTimeout)
        #expect(try engine.wait(request(.id("far"), gone: true)).get().element == nil)            // off screen counts as gone
    }

    @Test func anyRequestGetsAReplyAndNeverThrows() throws {
        let (engine, device) = make()
        func reply(_ path: String, _ body: String) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: engine.handle(path: path, body: Data(body.utf8))) as? [String: Any])
        }
        #expect(try reply("/nope", "{}")["ok"] as? Bool == false)
        #expect(try reply("/tap", "not json")["ok"] as? Bool == false)
        #expect(try reply("/tap", "{}")["ok"] as? Bool == false)
        device.failSnapshots = true
        let failed = try reply("/tree", #"{"bundleId":"b","system":false,"all":false}"#)
        #expect(failed["ok"] as? Bool == false)
        #expect((failed["failure"] as? [String: Any])?["code"] as? String == RunnerFailure.Code.internal)
        device.failSnapshots = false
        let ok = try reply("/tree", #"{"bundleId":"b","system":false,"all":false}"#)
        #expect(ok["ok"] as? Bool == true && (ok["result"] as? [String: Any])?["state"] as? String == "foreground")
        let health = try reply("/health", "")
        #expect((health["result"] as? [String: Any])?["protocolVersion"] as? Int == RunnerProtocol.version)
    }
}
