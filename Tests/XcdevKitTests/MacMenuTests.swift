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
        bar("Apple", [item("Sleep")]),
        bar("File", [item("New"), item("Save...", enabled: false), item("Export", children: [item("PDF"), item("PNG")])]),
        bar("Probe", [item("Bump by ten"), item("Services", children: [item("Open man Page")])]),
    ]

    @Test func theBarIsListedAsPathsWithDisabledMarkedAndServicesLeftOut() throws {
        let api = FakeAccessibility(app: FakeApp(windows: [], menuBar: Self.menuBar))
        let items = try MacMenu(api: api, app: api.application(pid: 7)).items()
        #expect(items.map(\.path) == ["Apple > Sleep", "File > New", "File > Save…", "File > Export > PDF", "File > Export > PNG", "Probe > Bump by ten"])
        #expect(items.map(\.enabled) == [true, true, false, true, true, true])
    }

    /// The Apple menu's items sleep, lock, or restart the Mac, or put a sheet or another app on the person's screen, so
    /// a path into the bar's first item is refused before any walk or press; it is still listed.
    @Test func theAppleMenuIsNeverPressed() throws {
        let api = FakeAccessibility(app: FakeApp(windows: [], menuBar: Self.menuBar))
        let refused = #expect(throws: XcdError.self) { try MacMenu(api: api, app: api.application(pid: 7)).press(path: "Apple > Sleep") }
        #expect(refused?.code == .platformUnsupported && refused?.message == "the Apple menu is the person's; xcd never presses it")
        #expect(refused?.next == "use the app's own menus (`xcd ui menu` lists them after the Apple menu)")
        #expect(!api.events.contains { $0.hasPrefix("AXPress") })
    }

    @Test func aPressByPathFiresTheItemAndTreatsThreeDotsAsAnEllipsis() throws {
        let api = FakeAccessibility(app: FakeApp(windows: [], menuBar: Self.menuBar))
        let menu = MacMenu(api: api, app: api.application(pid: 7))
        #expect(try menu.press(path: "Probe > Bump by ten").path == "Probe > Bump by ten" && api.events == ["AXPress Bump by ten"])
        #expect(try menu.press(path: "File > Export > PNG").path == "File > Export > PNG")
        let disabled = #expect(throws: XcdError.self) { try menu.press(path: "File > Save...") }
        #expect(disabled?.code == .elementNotHittable && disabled?.message == "File > Save… is disabled" && disabled?.next == "do what enables it first")
        let missing = #expect(throws: XcdError.self) { try menu.press(path: "File > Print") }
        #expect(missing?.code == .elementNotFound && missing?.message == "no menu item File > Print")
        #expect(missing?.next == "run `xcd ui menu` to list the menu bar" && missing?.details.contains("File > New") == true)
        let single = #expect(throws: XcdError.self) { try menu.press(path: "File") }
        #expect(single?.code == .usage && single?.message == "'File' is not a menu path")
        #expect(single?.next == "write it as \"<Menu> > <Item>\", e.g. \"File > Save…\"")
    }

    /// The bar item's menu is level 1 and two submenus nest below it: four segments are listed, five are not.
    @Test func submenusAreListedToThreeLevelsAndNoDeeper() throws {
        let deep = Self.item("A", children: [Self.item("B", children: [Self.item("C", children: [Self.item("D")])])])
        let api = FakeAccessibility(app: FakeApp(windows: [], menuBar: [Self.bar("M", [deep])]))
        let paths = try MacMenu(api: api, app: api.application(pid: 7)).items().map(\.path)
        #expect(paths == ["M > A > B > C"])
    }

    /// A press on a submenu's parent could open the submenu on screen, so it is refused and nothing is performed.
    @Test func aSubmenuIsNotPressed() throws {
        let api = FakeAccessibility(app: FakeApp(windows: [], menuBar: Self.menuBar))
        let refused = #expect(throws: XcdError.self) { try MacMenu(api: api, app: api.application(pid: 7)).press(path: "File > Export") }
        #expect(refused?.code == .elementNotHittable && refused?.message == "'File > Export' is a submenu, not an item")
        #expect(refused?.next == "name an item inside it, from `xcd ui menu`" && api.events.isEmpty)
    }
}
