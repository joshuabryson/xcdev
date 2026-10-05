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
        let (engine, device) = make()
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

    @Test func anAmbiguousTargetListsItsCandidatesWithRefs() {
        let row = { (y: Double) in TreeBuilderTests.node(9, label: "Delete", frame: ScreenRect(x: 0, y: y, w: 100, h: 40)) }
        let (engine, device) = make(FakeDevice(app: TreeBuilderTests.node(2, frame: Self.screen, [row(100), row(200)]), system: Self.home))
        guard case .failure(let failure) = engine.tap(request(.label("Delete"))) else { Issue.record("tapped"); return }
        #expect(failure.code == RunnerFailure.Code.ambiguous && failure.candidates.map(\.ref) == ["e1", "e2"])
        #expect(device.taps.isEmpty && device.pauses == 0)                 // no polling: waiting won't make it unique
        #expect((try? engine.tap(request(.ref("e2"))).get()) != nil)       // the candidates' refs work
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
