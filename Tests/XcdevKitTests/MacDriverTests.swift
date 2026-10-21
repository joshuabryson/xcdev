import ApplicationServices
import Foundation
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

    /// A window's top-left often sits on a screen's top edge, which the screen's frame leaves out, so the screen that
    /// counts is the one under the window's centre. The second screen's top edge is Quartz y -458 (982 - 1440).
    @Test func theScaleIsTheScreenUnderTheWindowsCentre() {
        let frames = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: 0, width: 2560, height: 1440)]
        #expect(SystemAccessibility.screenIndex(containing: ScreenRect(x: 1600, y: -458, w: 900, h: 552), frames: frames) == 1)
        #expect(SystemAccessibility.screenIndex(containing: ScreenRect(x: 0, y: 0, w: 900, h: 552), frames: frames) == 0)
        #expect(SystemAccessibility.screenIndex(containing: ScreenRect(x: 9000, y: 0, w: 10, h: 10), frames: frames) == nil)
    }

    @Test func theSystemAndAlertsAreNotAMacThing() {
        let driver = MacDriver(pid: 7, api: FakeAccessibility(app: FakeApp(windows: [Self.window])))
        #expect(driver.systemAlert() == nil)
        let refused = #expect(throws: RunnerFailure.self) { try driver.systemSnapshot() }
        #expect(refused?.code == RunnerFailure.Code.unsupported)
    }

    func driver(_ app: FakeApp = FakeApp(windows: [Self.window])) throws -> (MacDriver, FakeAccessibility, [FlatNode]) {
        let api = FakeAccessibility(app: app)
        let driver = MacDriver(pid: 7, api: api)
        var nodes: [FlatNode] = []
        TreeBuilder.flatten(try driver.appSnapshot("dev.x"), source: .app, into: &nodes)
        return (driver, api, nodes)
    }
    func node(_ nodes: [FlatNode], _ id: String) throws -> FlatNode { try #require(nodes.first { $0.identifier == id }) }

    @Test func aTapPressesAButtonAndFocusesAField() throws {
        let (driver, api, nodes) = try driver()
        try driver.tap(node: try node(nodes, "increment"))
        try driver.tap(node: try node(nodes, "name"))
        #expect(api.events == ["AXPress increment", "set AXFocused name bool(true)"])
    }

    @Test func aTapOnAnElementWithoutAPressActionIsNotHittable() throws {
        let (driver, _, nodes) = try driver()
        let failure = #expect(throws: RunnerFailure.self) { try driver.tap(node: try node(nodes, "count")) }
        #expect(failure?.code == RunnerFailure.Code.notHittable && failure?.message.contains("no press action") == true)
    }

    /// The real AXShowMenu answers cannotComplete though the menu opens, so the fake answers false and the driver goes on.
    @Test func aLongPressShowsTheContextMenuWhateverTheActionAnswers() throws {
        var row = MacSnapshotTests.row
        row.actions = ["AXPress", "AXShowMenu"]
        let (menuDriver, api, nodes) = try driver(FakeApp(windows: [MacSnapshotTests.window([row])]))
        try menuDriver.press(node: try node(nodes, "row-35"), duration: 1)
        #expect(api.events == ["AXShowMenu row-35"])
        let (plain, _, plainNodes) = try driver()
        let refused = #expect(throws: RunnerFailure.self) { try plain.press(node: try node(plainNodes, "increment"), duration: 1) }
        #expect(refused?.code == RunnerFailure.Code.notHittable && refused?.message.contains("no context menu") == true)
    }

    @Test func typingPostsOneEventPerCharacterWithControlKeysForNewlineTabAndDelete() throws {
        let (driver, api, nodes) = try driver()
        try driver.focus(node: try node(nodes, "name"))
        try driver.typeText("\u{8}hé\t\n")
        #expect(api.events.dropFirst() == ["key 51", "key \"h\"", "key \"é\"", "key 48", "key 36"])
        #expect(try api.string(kAXValueAttribute, of: AXElement(token: try #require(api.token(of: "name")))) == "vhé")
    }

    @Test func aLongTextGoesThroughWhole() throws {
        let (driver, api, nodes) = try driver()
        try driver.focus(node: try node(nodes, "name"))
        try driver.typeText(String(repeating: "x", count: 2000))
        #expect(api.events.count == 2001)
        #expect(try api.string(kAXValueAttribute, of: AXElement(token: try #require(api.token(of: "name")))) == "v1" + String(repeating: "x", count: 2000))
    }

    @Test func aFieldThatWillNotFocusIsNotHittableAndClearSetsTheFocusedValueToEmpty() throws {
        let (driver, api, nodes) = try driver()
        let refused = #expect(throws: RunnerFailure.self) { try driver.focus(node: try node(nodes, "increment")) }
        #expect(refused?.code == RunnerFailure.Code.notHittable && refused?.message.contains("keyboard focus") == true)
        try driver.focus(node: try node(nodes, "name"))
        try driver.pressKey("a", command: true)
        #expect(api.events.last == "set AXValue name string(\"\")")
        let chord = #expect(throws: RunnerFailure.self) { try driver.pressKey("s", command: true) }
        #expect(chord?.code == RunnerFailure.Code.unsupported && chord?.message == MacDriver.Refusal.noChord)
    }

    @Test func aFocusReadThatFailsIsReportedLikeAnyOtherAXError() throws {
        let (driver, api, nodes) = try driver()
        let field = try node(nodes, "name")
        api.failing = ["name"]
        let failure = #expect(throws: RunnerFailure.self) { try driver.focus(node: field) }
        #expect(failure?.message.contains("system prompt") == true)
    }

    @Test func aSwipeScrollsTheEnclosingScrollAreaByItsBarAndADirectionDragScrollsTheFirstOne() throws {
        let bar = FakeNode(role: "AXScrollBar", subrole: "AXVerticalScrollBar", value: "0", identifier: "vbar", frame: ScreenRect(x: 2900, y: 400, w: 10, h: 200))
        let content = FakeNode(role: "AXGroup", identifier: "content", frame: ScreenRect(x: 2574, y: 400, w: 300, h: 800), children: [MacSnapshotTests.row])
        let area = FakeNode(role: "AXScrollArea", identifier: "list", frame: ScreenRect(x: 2574, y: 400, w: 300, h: 200), children: [content, bar])
        let (driver, api, nodes) = try driver(FakeApp(windows: [MacSnapshotTests.window([area])]))
        #expect(try driver.scroll(node: try node(nodes, "row-35"), direction: .up) == true)
        #expect(api.events.last == "set AXValue vbar number(0.25)")       // visible 200 of 800: a quarter per page
        try driver.drag(from: ScreenPoint(x: 100, y: 300), to: ScreenPoint(x: 100, y: 100), duration: 0.3)
        #expect(api.events.last == "set AXValue vbar number(0.5)")
        let outside = #expect(throws: RunnerFailure.self) { try driver.scroll(node: try node(nodes, "list"), direction: .left) }
        #expect(outside?.code == RunnerFailure.Code.notHittable)              // no horizontal bar
    }

    @Test func whatABackgroundMacAppCannotDoIsRefusedWithTheReason() throws {
        let (driver, _, _) = try driver()
        let click = #expect(throws: RunnerFailure.self) { try driver.tap(x: 10, y: 10) }
        #expect(click?.code == RunnerFailure.Code.unsupported && click?.message == MacDriver.Refusal.pointClick)
        #expect(throws: RunnerFailure.self) { try driver.press(x: 10, y: 10, duration: 1) }
        #expect(throws: RunnerFailure.self) { _ = try driver.pressButton(.home) }
        #expect(throws: RunnerFailure.self) { try driver.rotate(to: .landscapeLeft) }
        #expect(driver.setPasteboard(image: Data([0x89, 0x50])) == false)
    }
}
