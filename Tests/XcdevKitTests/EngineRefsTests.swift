import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Refs from one tree to the next: an element keeps its ref while each new tree lists it, and a number
/// is never given to a second element, so an old ref either still names its element or is refused.
@Suite struct EngineRefsTests {
    static let screen = TreeBuilderTests.screen
    static let treeRequest = TreeRequest(bundleId: "dev.xcdev.SampleApp", system: false, all: false)

    static func text(_ id: String, y: Double) -> SnapshotNode {
        TreeBuilderTests.node(48, id: id, label: id.capitalized, frame: ScreenRect(x: 24, y: y, w: 354, h: 20))
    }

    static func button(_ id: String, y: Double) -> SnapshotNode {
        TreeBuilderTests.node(9, id: id, label: id.capitalized, frame: ScreenRect(x: 24, y: y, w: 354, h: 50))
    }

    static func app(_ children: [SnapshotNode]) -> SnapshotNode {
        TreeBuilderTests.node(2, label: "SampleApp", frame: screen, [TreeBuilderTests.node(4, frame: screen, children)])
    }

    static let field = TreeBuilderTests.node(50, id: "passphrase", label: "Passphrase", frame: ScreenRect(x: 24, y: 300, w: 354, h: 44))
    /// A lock screen: a title, a secure field, and a button.
    static let locked = app([text("locked", y: 100), field, button("unlock", y: 700)])
    /// The same screen once a hint has appeared between the title and the field.
    static let lockedWithHint = app([text("locked", y: 100), text("hint", y: 200), field, button("unlock", y: 700)])
    /// Another screen, with nothing of the lock screen on it.
    static let home = app([text("welcome", y: 100), button("signOut", y: 700)])

    func make(_ app: SnapshotNode) -> (RunnerEngine, FakeDevice) {
        let device = FakeDevice(app: app, system: RunnerEngineTests.home)
        return (RunnerEngine(device: device), device)
    }

    func request(_ target: TargetSpec) -> TargetRequest {
        TargetRequest(bundleId: "dev.xcdev.SampleApp", system: false, target: target, role: nil, index: nil, timeout: 0.2, gone: false)
    }

    /// Reported by an agent: the field was e5 in one tree and e7 in the next, and the old ref then named another element.
    @Test func anElementKeepsItsRefWhenTheNextTreeListsItOnAnotherRow() throws {
        let (engine, device) = make(Self.locked)
        let first = try engine.tree(Self.treeRequest).get()
        #expect(first.elements.map(\.identifier) == ["locked", "passphrase", "unlock"] && first.elements.map(\.ref) == ["e1", "e2", "e3"])
        device.app = Self.lockedWithHint
        let second = try engine.tree(Self.treeRequest).get()
        #expect(second.elements.map(\.identifier) == ["locked", "hint", "passphrase", "unlock"])
        #expect(second.elements.map(\.ref) == ["e1", "e4", "e2", "e3"], "the hint is new, so it gets a number no element has had")
        _ = try engine.tap(request(.ref("e2"))).get()
        #expect(device.events == ["tap 201,322"], "e2 is still the field")
    }

    @Test func aNumberIsNeverGivenToASecondElement() throws {
        let (engine, device) = make(Self.locked)
        _ = try engine.tree(Self.treeRequest).get()
        device.app = Self.home
        #expect(try engine.tree(Self.treeRequest).get().elements.map(\.ref) == ["e4", "e5"])
        // A ref of the first tree names nothing now. Counting from e1 again, e2 would be the Sign Out button.
        guard case .failure(let stale) = engine.tap(request(.ref("e2"))) else { Issue.record("tapped \(device.events)"); return }
        #expect(stale.code == RunnerFailure.Code.staleRef && stale.message == "that ref is not in the latest tree" && device.events.isEmpty)
        // Back on the first screen its elements are new to the table: a ref lasts only while each tree lists its element.
        device.app = Self.locked
        #expect(try engine.tree(Self.treeRequest).get().elements.map(\.ref) == ["e6", "e7", "e8"])
    }

    @Test func aRefWhoseElementWentSinceTheLatestTreeSaysSo() throws {
        let (engine, device) = make(Self.locked)
        _ = try engine.tree(Self.treeRequest).get()
        device.app = Self.home
        guard case .failure(let gone) = engine.tap(request(.ref("e2"))) else { Issue.record("tapped \(device.events)"); return }
        #expect(gone.code == RunnerFailure.Code.staleRef && gone.message == "that ref no longer names one element on screen")
        guard case .failure(let unknown) = engine.wait(request(.ref("e9"))) else { Issue.record("waited"); return }
        #expect(unknown.code == RunnerFailure.Code.staleRef && unknown.message == "that ref is not in the latest tree")
    }

    @Test func theCandidatesOfAnAmbiguousTargetKeepTheRefsTheyHadAndTheOthersStay() throws {
        let row = { (y: Double) in TreeBuilderTests.node(9, label: "Delete", frame: ScreenRect(x: 0, y: y, w: 100, h: 40)) }
        let (engine, device) = make(Self.app([row(100), row(200), row(5000), Self.text("total", y: 400)]))
        let tree = try engine.tree(Self.treeRequest).get()
        #expect(tree.elements.map(\.label) == ["Delete", "Delete", "Total"] && tree.elements.map(\.ref) == ["e1", "e2", "e3"])
        guard case .failure(let failure) = engine.tap(request(.label("Delete"))) else { Issue.record("tapped"); return }
        // The off-screen row was in no tree, so it gets the next number: e3 stays the total's.
        #expect(failure.code == RunnerFailure.Code.ambiguous && failure.candidates.map(\.ref) == ["e1", "e2", "e4"])
        _ = try engine.tap(request(.ref("e2"))).get()
        #expect(device.events == ["tap 50,220"])
        #expect(try engine.wait(request(.ref("e3"))).get().element?.identifier == "total", "a ref of the tree before the failure still works")
    }
}
