import ApplicationServices
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The Accessibility tree as the engine sees it.
@Suite struct MacSnapshotTests {
    static func window(_ children: [FakeNode], title: String = "Probe", x: Double = 2558, y: Double = 249) -> FakeNode {
        FakeNode(role: "AXWindow", title: title, frame: ScreenRect(x: x, y: y, w: 900, h: 552), children: children)
    }
    static let button = FakeNode(role: "AXButton", title: "Increment", identifier: "increment", frame: ScreenRect(x: 2574, y: 323, w: 85, h: 24), actions: ["AXPress"])
    static let field = FakeNode(role: "AXTextField", value: "v1", identifier: "name", placeholder: "Name", frame: ScreenRect(x: 2574, y: 360, w: 860, h: 22), focused: true)
    static let text = FakeNode(role: "AXStaticText", value: "count: 0", identifier: "count", frame: ScreenRect(x: 2574, y: 290, w: 60, h: 16))
    static let row = FakeNode(role: "AXButton", title: "Row 35", identifier: "row-35", frame: ScreenRect(x: 0, y: 1117, w: 0, h: 0), actions: ["AXPress"])

    /// Every node of the tree, the root included.
    static func count(_ node: SnapshotNode) -> Int { 1 + node.children.map(count).reduce(0, +) }

    @Test func windowsBecomeTheRootsChildrenWithFramesInTheirOwnCoordinates() throws {
        let api = FakeAccessibility(app: FakeApp(windows: [Self.window([Self.text, Self.button, Self.field, Self.row])]))
        let scene = try MacSnapshot(api: api).read(app: api.application(pid: 7))
        #expect(scene.root.elementType == 2 && scene.root.frame == ScreenRect(x: 0, y: 0, w: 900, h: 552))
        let window = try #require(scene.root.children.first)
        #expect(window.elementType == 4 && window.frame == ScreenRect(x: 0, y: 0, w: 900, h: 552) && window.label == "Probe")
        let button = try #require(window.children.first { $0.identifier == "increment" })
        #expect(button.elementType == 9 && button.label == "Increment" && button.frame == ScreenRect(x: 16, y: 74, w: 85, h: 24))
        #expect(button.handle != nil && scene.hidden == false && scene.capped == false)
    }

    @Test func labelsValuesPlaceholdersAndFocusComeFromTheRightAttributes() throws {
        let api = FakeAccessibility(app: FakeApp(windows: [Self.window([Self.text, Self.field])]))
        let window = try #require(MacSnapshot(api: api).read(app: api.application(pid: 7)).root.children.first)
        let text = try #require(window.children.first { $0.identifier == "count" })
        #expect(text.elementType == 48 && text.label == "count: 0" && text.value == "count: 0")
        let field = try #require(window.children.first { $0.identifier == "name" })
        #expect(field.elementType == 49 && field.value == "v1" && field.placeholder == "Name" && field.focused == true && field.label == "")
    }

    @Test func aZeroSizedRowKeepsItsZeroFrameSoTheEngineListsItOffscreen() throws {
        let api = FakeAccessibility(app: FakeApp(windows: [Self.window([Self.row])]))
        let window = try #require(MacSnapshot(api: api).read(app: api.application(pid: 7)).root.children.first)
        #expect(window.children.first?.frame == ScreenRect(x: 0, y: 0, w: 0, h: 0))
    }

    /// A context menu sits under the cell of the row it opened on; a pop-up menu under the application.
    @Test func openMenusAreReadUnderAWindowsCellAndUnderTheApplicationButNeverFromTheMenuBar() throws {
        let action = FakeNode(role: "AXMenuItem", title: "Row action 3", frame: ScreenRect(x: 2600, y: 400, w: 120, h: 20), actions: ["AXPress"])
        let context = FakeNode(role: "AXMenu", identifier: "row-3", frame: ScreenRect(x: 2600, y: 400, w: 120, h: 20), children: [action])
        let cell = FakeNode(role: "AXCell", frame: ScreenRect(x: 2574, y: 390, w: 860, h: 16), children: [context])
        let copy = FakeNode(role: "AXMenuItem", title: "Copy", frame: ScreenRect(x: 2700, y: 300, w: 100, h: 20), actions: ["AXPress"])
        let popUp = FakeNode(role: "AXMenu", frame: ScreenRect(x: 2700, y: 300, w: 100, h: 40), children: [copy])
        let file = FakeNode(role: "AXMenuBarItem", title: "File", frame: ScreenRect(x: 40, y: 0, w: 40, h: 24), actions: ["AXPress"])
        let windows = [Self.window([cell]), Self.window([], title: "Inspector", x: 100, y: 100)]
        let api = FakeAccessibility(app: FakeApp(windows: windows, menus: [popUp], menuBar: [file]))
        let root = try MacSnapshot(api: api).read(app: api.application(pid: 7)).root
        #expect(root.children.map(\.elementType) == [4, 4, 53])
        let inCell = try #require(root.children[0].children.first?.children.first)
        #expect(inCell.elementType == 53 && inCell.identifier == "row-3" && inCell.frame == ScreenRect(x: 42, y: 151, w: 120, h: 20))
        #expect(inCell.children.first?.elementType == 54 && inCell.children.first?.label == "Row action 3")
        // Measured from the main window's origin, not from the Inspector's, which was walked last.
        #expect(root.children[2].frame == ScreenRect(x: 142, y: 51, w: 100, h: 40) && root.children[2].children.first?.label == "Copy")
    }

    @Test func aHiddenAppAndASecondWindowAreReported() throws {
        let api = FakeAccessibility(app: FakeApp(windows: [Self.window([Self.button]), Self.window([], title: "Inspector", x: 100, y: 100)], hidden: true))
        let scene = try MacSnapshot(api: api).read(app: api.application(pid: 7))
        #expect(scene.hidden && scene.windows.count == 2 && scene.root.children[1].label == "Inspector")
        #expect(scene.root.children[1].frame == ScreenRect(x: 0, y: 0, w: 900, h: 552))
        #expect(scene.mainWindow == scene.windows.first && scene.mainTitle == "Probe")
    }

    /// After a link, `AXMainWindow` can name an empty twin while the controls sit in the next window.
    /// The twin still has its title-bar buttons, which are not content.
    @Test func theMainWindowIsTheOneWithContentWhenAXMainWindowIsAnEmptyTwin() throws {
        let popUp = FakeNode(role: "AXMenu", frame: ScreenRect(x: 2700, y: 300, w: 100, h: 40))
        let chrome = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton"].map {
            FakeNode(role: "AXButton", subrole: $0, frame: ScreenRect(x: 2566, y: 255, w: 14, h: 16), actions: ["AXPress"])
        }
        let windows = [Self.window(chrome, title: "Twin"), Self.window([Self.button], title: "Probe", x: 100, y: 100)]
        let api = FakeAccessibility(app: FakeApp(windows: windows, menus: [popUp]))
        #expect(try api.element(kAXMainWindowAttribute, of: api.application(pid: 7)) == AXElement(token: 1))   // the twin, as AX says
        let scene = try MacSnapshot(api: api).read(app: api.application(pid: 7))
        #expect(scene.windows.count == 2 && scene.mainWindow == scene.windows[1] && scene.mainTitle == "Probe")
        #expect(scene.root.children[2].frame == ScreenRect(x: 2600, y: 200, w: 100, h: 40))    // measured from the chosen window
    }

    /// A locked screen's tree, as measured on Finder: `AXWindows` and `AXMainWindow` name the application itself, whose
    /// children list it again beside the menu bar. Nothing is read twice, the menu bar stays out, and the read ends at once.
    @Test func aLockedScreensTreeThatListsTheApplicationAsItsWindowsIsReadWithoutLooping() throws {
        let copy = FakeNode(role: "AXMenuItem", title: "Copy", frame: ScreenRect(x: 10, y: 10, w: 100, h: 20), actions: ["AXPress"])
        let popUp = FakeNode(role: "AXMenu", frame: ScreenRect(x: 10, y: 10, w: 100, h: 40), children: [copy, .application, .ancestor(0)])
        let file = FakeNode(role: "AXMenuBarItem", title: "File", frame: ScreenRect(x: 40, y: 0, w: 40, h: 24), actions: ["AXPress"])
        let api = FakeAccessibility(app: FakeApp(windows: [.application, .application, .application], menus: [popUp], menuBar: [file]))
        let app = api.application(pid: 7)
        #expect(try api.elements(kAXWindowsAttribute, of: app) == [app, app, app] && api.element(kAXMainWindowAttribute, of: app) == app)
        let scene = try MacSnapshot(api: api).read(app: app)
        #expect(scene.windows.isEmpty && scene.mainWindow == nil && scene.capped == false && scene.root.frame == ScreenRect(x: 0, y: 0, w: 0, h: 0))
        #expect(scene.root.children.map(\.elementType) == [53] && scene.root.children[0].children.map(\.label) == ["Copy"])
        #expect(Self.count(scene.root) == 3)    // the application, the menu, its one item: no repeats and no menu bar
        // The same loops and a menu bar inside a window: none of them is walked, and none of them is content.
        let bar = FakeNode(role: "AXMenuBar", frame: ScreenRect(x: 0, y: 0, w: 900, h: 24), children: [file])
        let looping = FakeAccessibility(app: FakeApp(windows: [Self.window([bar, .application, .ancestor(0)])]))
        let window = try #require(looping.elements(kAXWindowsAttribute, of: looping.application(pid: 7)).first)
        let inWindow = try MacSnapshot(api: looping).read(app: looping.application(pid: 7))
        #expect(inWindow.root.children.first?.children.isEmpty == true && inWindow.capped == false)
        #expect(try MacSnapshot(api: looping).holdsContent(window, app: looping.application(pid: 7)) == false)
    }

    @Test func theTreeStopsAtTheDepthCapAndSaysSo() throws {
        var deep = FakeNode(role: "AXGroup", frame: ScreenRect(x: 0, y: 0, w: 10, h: 10))
        for _ in 0..<50 { deep = FakeNode(role: "AXGroup", frame: ScreenRect(x: 0, y: 0, w: 10, h: 10), children: [deep]) }
        let api = FakeAccessibility(app: FakeApp(windows: [Self.window([deep])]))
        let scene = try MacSnapshot(api: api).read(app: api.application(pid: 7))
        #expect(scene.capped)
        var depth = 0
        var node = scene.root
        while let child = node.children.first { depth += 1; node = child }
        #expect(depth == MacSnapshot.maxDepth)
    }

    @Test func theTreeStopsAtTheNodeCapAndSaysSo() throws {
        var rows: [FakeNode] = []
        for index in 0...MacSnapshot.maxNodes {
            rows.append(FakeNode(role: "AXStaticText", value: "row \(index)", frame: ScreenRect(x: 2574, y: 300, w: 60, h: 16)))
        }
        let api = FakeAccessibility(app: FakeApp(windows: [Self.window(rows)]))
        let scene = try MacSnapshot(api: api).read(app: api.application(pid: 7))
        #expect(scene.capped && Self.count(scene.root) == MacSnapshot.maxNodes)
    }

    @Test func rolesAndSubrolesMapOntoTheEnginesElementTypes() {
        #expect(MacRoles.elementType(role: "AXButton", subrole: nil) == 9)
        #expect(MacRoles.elementType(role: "AXButton", subrole: "AXToolbarButton") == 17)
        #expect(MacRoles.elementType(role: "AXCheckBox", subrole: "AXSwitch") == 40)
        #expect(MacRoles.elementType(role: "AXTextField", subrole: "AXSecureTextField") == 50)
        #expect(MacRoles.elementType(role: "AXTextField", subrole: "AXSearchField") == 45)
        #expect(MacRoles.elementType(role: "AXRow", subrole: nil) == 75 && MacRoles.elementType(role: "AXCell", subrole: nil) == 75)
        #expect(MacRoles.elementType(role: "AXSheet", subrole: nil) == 5 && MacRoles.elementType(role: "AXDialog", subrole: nil) == 8)
        // SwiftUI's own main window reports the AXDialog subrole, so a window stays a window.
        #expect(MacRoles.elementType(role: "AXWindow", subrole: "AXDialog") == 4 && MacRoles.elementType(role: "AXWindow", subrole: "AXSystemDialog") == 7)
        #expect(MacRoles.elementType(role: "AXScrollArea", subrole: nil) == 46 && MacRoles.elementType(role: "AXIncrementor", subrole: nil) == 79)
        #expect(MacRoles.elementType(role: "AXRadioButton", subrole: nil, parentType: 23) == 80)
        #expect(ElementRole.name(for: MacRoles.elementType(role: "AXColorWell", subrole: nil)) == "other")
    }
}
