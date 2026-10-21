import ApplicationServices
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `MacDriver` as `DeviceDriving`.
@Suite struct MacDriverTests {
    static let window = MacSnapshotTests.window([MacSnapshotTests.text, MacSnapshotTests.button, MacSnapshotTests.field, MacSnapshotTests.row])

    @Test func aRunningAppIsForegroundHiddenOrNotAndAGoneOneIsNotRunning() {
        let api = FakeAccessibility(app: FakeApp(windows: [Self.window], hidden: true))
        let driver = MacDriver(pid: 7, api: api)
        #expect(driver.appState("dev.x") == .foreground)
        api.setRunning(false)
        #expect(driver.appState("dev.x") == .notRunning)
    }

    @Test func theSnapshotIsTheWindowTreeAndTheScaleIsTheWindowsScreens() throws {
        let api = FakeAccessibility(app: FakeApp(windows: [Self.window], scale: 1))
        let driver = MacDriver(pid: 7, api: api)
        let root = try driver.appSnapshot("dev.x")
        #expect(root.children.first?.children.count == 4 && driver.scale == 1 && driver.orientation == "none")
        #expect(driver.lastScene?.windows.count == 1 && driver.keyboardAppears == false && api.events.isEmpty)    // a read acts on nothing
        var nodes: [FlatNode] = []
        TreeBuilder.flatten(root, source: .app, into: &nodes)
        let button = try #require(nodes.first { $0.identifier == "increment" })
        #expect(try api.string(kAXIdentifierAttribute, of: driver.element(of: button)) == "increment")
    }

    @Test func anAppWithNoWindowGivesAnEmptySnapshotTheEngineCanReport() throws {
        let api = FakeAccessibility(app: FakeApp(windows: []))
        let engine = RunnerEngine(device: MacDriver(pid: 7, api: api))
        guard case .success(let tree) = engine.tree(TreeRequest(bundleId: "dev.x", system: false, all: false)) else { Issue.record("the tree failed"); return }
        #expect(tree.elements.isEmpty && tree.state == "foreground" && tree.hidden == nil)    // the session sets hidden, not the engine
    }

    @Test func aFailedAttributeReadBecomesARunnerFailureNamingThePromptPossibility() {
        let api = FakeAccessibility(app: FakeApp(windows: [Self.window]))
        api.failing = ["increment"]
        let engine = RunnerEngine(device: MacDriver(pid: 7, api: api))
        guard case .failure(let failure) = engine.tree(TreeRequest(bundleId: "dev.x", system: false, all: false)) else { Issue.record("expected a failure"); return }
        #expect(failure.code == RunnerFailure.Code.internal && failure.message.contains("system prompt"))
        let gone = MacDriver.failure(for: .elementGone("AXRole"), during: "reading the tree")
        #expect(gone.code == RunnerFailure.Code.internal && gone.message == "the element is no longer there; the app may have quit or the window closed")
    }

    /// The engine re-reads the tree while it polls, so an element met again must keep its token, not grow the table.
    /// Creating an application element and comparing two of them are local: no app is asked anything.
    @Test func theRealTableGivesAnElementMetAgainItsFirstToken() {
        let api = SystemAccessibility()
        let first = api.application(pid: 7)
        #expect(api.application(pid: 7) == first && api.application(pid: 8) == AXElement(token: first.token + 1))
        #expect(throws: MacAXError.elementGone(kAXRoleAttribute)) { try api.string(kAXRoleAttribute, of: AXElement(token: 99)) }
    }

    @Test func theSystemAndAlertsAreNotAMacThing() {
        let driver = MacDriver(pid: 7, api: FakeAccessibility(app: FakeApp(windows: [Self.window])))
        #expect(driver.systemAlert() == nil)
        let refused = #expect(throws: RunnerFailure.self) { try driver.systemSnapshot() }
        #expect(refused?.code == RunnerFailure.Code.unsupported)
    }
}
