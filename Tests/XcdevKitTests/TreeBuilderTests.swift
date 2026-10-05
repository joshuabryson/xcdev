import Foundation
import Testing
@testable import XcdevKit

@Suite struct TreeBuilderTests {
    static func node(_ type: Int, id: String = "", label: String = "", value: String? = nil, placeholder: String? = nil,
                     frame: ScreenRect = ScreenRect(x: 0, y: 0, w: 100, h: 40), enabled: Bool = true,
                     _ children: [SnapshotNode] = []) -> SnapshotNode {
        SnapshotNode(elementType: type, identifier: id, label: label, value: value, placeholder: placeholder, frame: frame,
                     enabled: enabled, selected: false, children: children)
    }
    static let screen = ScreenRect(x: 0, y: 0, w: 402, h: 874)

    /// application > window > [other > [button "Sign In" > text "Sign In"], textField, text, button offscreen, keyboard > key]
    static let app = node(2, label: "SampleApp", frame: screen, [
        node(4, frame: screen, [
            node(1, frame: screen, [
                node(9, id: "signIn", label: "Sign In", frame: ScreenRect(x: 24, y: 700, w: 354, h: 50), [
                    node(48, label: "Sign In", frame: ScreenRect(x: 150, y: 715, w: 100, h: 20)),
                ]),
                node(49, id: "email", label: "", value: "Email", placeholder: "Email", frame: ScreenRect(x: 24, y: 300, w: 354, h: 44)),
                node(48, label: "Welcome back", frame: ScreenRect(x: 24, y: 120, w: 200, h: 40)),
                node(9, id: "far", label: "Far away", frame: ScreenRect(x: 24, y: 3574, w: 100, h: 44)),
                node(9, label: "", frame: ScreenRect(x: 350, y: 60, w: 44, h: 44)),
            ]),
            node(19, frame: ScreenRect(x: 0, y: 600, w: 402, h: 274), [node(20, label: "q", frame: ScreenRect(x: 4, y: 610, w: 36, h: 42))]),
        ]),
    ])

    func flat(_ root: SnapshotNode = app) -> [FlatNode] {
        var nodes: [FlatNode] = []
        TreeBuilder.flatten(root, source: .app, into: &nodes)
        return nodes
    }

    @Test func rolesComeFromElementTypeNumbers() {
        #expect(ElementRole.name(for: 9) == "button" && ElementRole.name(for: 48) == "text")
        #expect(ElementRole.name(for: 49) == "textField" && ElementRole.name(for: 45) == "searchField")
        #expect(ElementRole.name(for: 7) == "alert" && ElementRole.name(for: 75) == "cell")
        #expect(ElementRole.name(for: 1) == "other" && ElementRole.name(for: 9999) == "other")
        #expect(ElementRole.name(for: 23) == "tabGroup" && ElementRole.name(for: 47) == "scrollBar")
        #expect(ElementRole.interactive.contains("button") && !ElementRole.interactive.contains("text"))
        #expect(ElementRole.structural.contains("scrollBar") && ElementRole.structural.contains("tabGroup"))
    }

    @Test func flatteningKeepsOrderDepthParentsAndSignatures() {
        let nodes = flat()
        #expect(nodes.map(\.role) == ["application", "window", "other", "button", "text", "textField", "text", "button", "button",
                                      "keyboard", "key"])
        #expect(nodes[3].depth == 3 && nodes[3].parent == 2 && nodes[4].parent == 3)
        #expect(nodes[3].signature == RefSignature(role: "button", identifier: "signIn", label: "Sign In", path: [2, 0, 4, 0, 1, 0, 9, 0], source: .app))
        #expect(nodes[7].signature.path == [2, 0, 4, 0, 1, 0, 9, 1] && nodes[8].signature.path == [2, 0, 4, 0, 1, 0, 9, 2])   // 2nd and 3rd buttons
        #expect(nodes[10].inKeyboard && !nodes[3].inKeyboard)
        #expect(nodes.allSatisfy { $0.window == 0 })
    }

    @Test func anEmptyFieldsPlaceholderIsNotItsValue() {
        let field = flat()[5]
        #expect(field.value == "" && field.placeholder == "Email")
    }

    @Test func theDefaultFilterShowsWhatAnAgentCanUse() {
        let nodes = flat()
        let shown = TreeBuilder.displayed(nodes, screen: Self.screen, all: false).map { nodes[$0] }
        // The labelled button, the field, the text, and the unlabelled icon button. Not: containers, the button's own
        // label text, the off-screen button, or keyboard keys.
        #expect(shown.map(\.identifier) == ["signIn", "email", "", ""])
        #expect(shown.map(\.role) == ["button", "textField", "text", "button"])
        #expect(TreeBuilder.displayed(nodes, screen: Self.screen, all: true).count == nodes.count)
    }

    @Test func onScreenMeansTheCentreIsOnScreenAndTheFrameIsNotEmpty() {
        let nodes = flat()
        #expect(TreeBuilder.isOnScreen(nodes[3], screen: Self.screen))
        #expect(!TreeBuilder.isOnScreen(nodes[7], screen: Self.screen))
        var empty = nodes[3]
        empty.frame = ScreenRect(x: 10, y: 10, w: 0, h: 0)
        #expect(!TreeBuilder.isOnScreen(empty, screen: Self.screen))
    }

    @Test func elementsCarryTheirRefAndOffscreenFlag() {
        let nodes = flat()
        let element = TreeBuilder.element(nodes[7], ref: "e9", screen: Self.screen)
        #expect(element.ref == "e9" && element.offscreen && element.role == "button" && element.source == .app)
        #expect(element.frame.text == "24,3574 100x44")
        #expect(ScreenRect(x: 16, y: 380.33, w: 370, h: 52).text == "16,380.3 370x52")
    }

    @Test func aSecondWindowGetsTheNextWindowNumber() {
        let two = Self.node(2, frame: Self.screen, [Self.node(4, [Self.node(9, label: "A")]), Self.node(4, [Self.node(9, label: "B")])])
        #expect(flat(two).filter { $0.role == "button" }.map(\.window) == [0, 1])
    }

    @Test func differentElementsNeverShareASignature() {
        // Build tree with elements that could collide: button and cell both with text "Delete", plus unmapped types
        let tree = Self.node(2, frame: Self.screen, [
            Self.node(4, frame: Self.screen, [
                Self.node(1, frame: Self.screen, [
                    Self.node(9, label: "Delete"),          // button
                    Self.node(75, label: "Delete"),         // cell
                    Self.node(1, label: ""),                // other (same type as parent's first child)
                    Self.node(9999, label: ""),             // unmapped type (will be "other")
                ]),
            ]),
        ])
        let appNodes = flat(tree)
        let appSignatures = Set(appNodes.map { $0.signature })
        #expect(appSignatures.count == appNodes.count)  // All signatures unique for app source

        // Flatten same tree with system source; root signature should differ by source
        var systemNodes: [FlatNode] = []
        TreeBuilder.flatten(tree, source: .system, into: &systemNodes)
        #expect(appNodes[0].signature.source == .app && systemNodes[0].signature.source == .system)
        #expect(appNodes[0].signature != systemNodes[0].signature)
    }

    @Test func screenRectHandlesNonFiniteNumbers() {
        #expect(ScreenRect(x: .infinity, y: .nan, w: 1e20, h: 5).text == "?,? ?x5")
    }

    @Test func scrollBarIsStructuralAndNotDisplayedByDefault() {
        let tree = Self.node(2, frame: Self.screen, [
            Self.node(4, frame: Self.screen, [
                Self.node(47, value: "Vertical scroll bar, 2 pages", frame: ScreenRect(x: 390, y: 0, w: 12, h: 874)),
            ]),
        ])
        let nodes = flat(tree)
        let shown = TreeBuilder.displayed(nodes, screen: Self.screen, all: false)
        #expect(!shown.contains(1))  // scrollBar not shown by default
        let allShown = TreeBuilder.displayed(nodes, screen: Self.screen, all: true)
        #expect(allShown.contains(1))  // scrollBar shown with all: true
    }
}
