import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The menu bar as paths, and a press by path.
@Suite struct MacMenuTests {
    static func item(_ title: String, enabled: Bool = true, children: [FakeNode] = []) -> FakeNode {
        FakeNode(role: "AXMenuItem", title: title, frame: ScreenRect(x: 0, y: 0, w: 100, h: 20), enabled: enabled, actions: ["AXPress"],
                 children: children.isEmpty ? [] : [FakeNode(role: "AXMenu", frame: ScreenRect(x: 0, y: 0, w: 100, h: 60), children: children)])
    }
    static func bar(_ title: String, _ items: [FakeNode]) -> FakeNode {
        FakeNode(role: "AXMenuBarItem", title: title, frame: ScreenRect(x: 0, y: 0, w: 60, h: 22), actions: ["AXPress"],
                 children: [FakeNode(role: "AXMenu", frame: ScreenRect(x: 0, y: 0, w: 100, h: 100), children: items)])
    }
    static let menuBar = [
        bar("File", [item("New"), item("Save...", enabled: false), item("Export", children: [item("PDF"), item("PNG")])]),
        bar("Probe", [item("Bump by ten"), item("Services", children: [item("Open man Page")])]),
    ]

    @Test func theBarIsListedAsPathsWithDisabledMarkedAndServicesLeftOut() throws {
        let api = FakeAccessibility(app: FakeApp(windows: [], menuBar: Self.menuBar))
        let items = try MacMenu(api: api, app: api.application(pid: 7)).items()
        #expect(items.map(\.path) == ["File > New", "File > Save…", "File > Export > PDF", "File > Export > PNG", "Probe > Bump by ten"])
        #expect(items.map(\.enabled) == [true, false, true, true, true])
    }

    @Test func aPressByPathFiresTheItemAndTreatsThreeDotsAsAnEllipsis() throws {
        let api = FakeAccessibility(app: FakeApp(windows: [], menuBar: Self.menuBar))
        let menu = MacMenu(api: api, app: api.application(pid: 7))
        #expect(try menu.press(path: "Probe > Bump by ten").path == "Probe > Bump by ten" && api.events == ["AXPress Bump by ten"])
        #expect(try menu.press(path: "File > Export > PNG").path == "File > Export > PNG")
        let disabled = #expect(throws: XcdError.self) { try menu.press(path: "File > Save...") }
        #expect(disabled?.code == .elementNotHittable)
        let missing = #expect(throws: XcdError.self) { try menu.press(path: "File > Print") }
        #expect(missing?.code == .elementNotFound && missing?.details.contains("File > New") == true)
    }
}
