import ApplicationServices
import Foundation

extension MacDriver {
    /// Why a background Mac app refuses what a simulator does.
    public enum Refusal {
        public static let pointClick = "clicks posted to a background Mac app do not land; name the element instead (id:, label:, or a ref)"
        public static let noDrag = "a drag between points does not reach a background Mac app; swipe on an element with --on"
        public static let noButtons = "a Mac has no hardware buttons"
        public static let noRotation = "a Mac window does not rotate"
        public static let noChord = "keyboard shortcuts posted to a background Mac app do not land; use `xcd ui menu \"<Menu> > <Item>\"`"
    }

    static func unsupported(_ message: String) -> RunnerFailure { RunnerFailure(code: RunnerFailure.Code.unsupported, message: message) }

    /// Runs an Accessibility call, reporting its errors as every read does (`during` names what was being done).
    func guarded<T>(_ during: String, _ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as MacAXError { throw Self.failure(for: error, during: during) }
    }

    public func tap(x: Double, y: Double) throws { throw Self.unsupported(Refusal.pointClick) }
    public func press(x: Double, y: Double, duration: Double) throws { throw Self.unsupported(Refusal.pointClick) }
    public func pressButton(_ button: HardwareButton) throws -> Bool { throw Self.unsupported(Refusal.noButtons) }
    public func rotate(to orientation: DeviceOrientation) throws { throw Self.unsupported(Refusal.noRotation) }
    public func setPasteboard(text: String) { /* the Mac's pasteboard is the person's; nothing is written */ }
    public func setPasteboard(image: Data) -> Bool { false }

    public func tap(node: FlatNode) throws {
        if MacRoles.textEntry.contains(where: { ElementRole.name(for: $0) == node.role }) { return try focus(node: node) }
        let element = try element(of: node)
        guard api.actions(of: element).contains(kAXPressAction) else {
            throw RunnerFailure(code: RunnerFailure.Code.notHittable, message: "the element has no press action", frame: node.frame)
        }
        guard api.perform(kAXPressAction, on: element) else {
            throw RunnerFailure(code: RunnerFailure.Code.internal, message: "the app refused the press")
        }
    }

    /// Shows the element's context menu. The real `AXShowMenu` answers cannotComplete after about 1.5 s though the menu
    /// opens and its items fire (measured), so the answer is ignored.
    public func press(node: FlatNode, duration: Double) throws {
        let element = try element(of: node)
        guard api.actions(of: element).contains("AXShowMenu") else {
            throw RunnerFailure(code: RunnerFailure.Code.notHittable, message: "the element has no context menu action", frame: node.frame)
        }
        _ = api.perform("AXShowMenu", on: element)
    }

    /// Focuses the element. The set's answer is not trusted: a re-read decides whether it took focus.
    public func focus(node: FlatNode) throws {
        let element = try element(of: node)
        _ = api.set(kAXFocusedAttribute, of: element, to: .bool(true))
        let focused = try guarded("focusing the element") { try api.bool(kAXFocusedAttribute, of: element) }
        guard focused == true else {
            throw RunnerFailure(code: RunnerFailure.Code.notHittable, message: "the element would not take keyboard focus", frame: node.frame)
        }
        focusedElement = element
    }

    public func typeText(_ text: String) throws {
        for key in MacKeys.events(for: text) { api.postKey(key, to: pid) }
    }

    /// The engine's ⌘A (for `--clear`) empties the focused field's value, since a chord posted to a background app
    /// does not land; any other chord is refused.
    public func pressKey(_ key: String, command: Bool) throws {
        guard command else { return try typeText(key) }
        guard key == "a" else { throw Self.unsupported(Refusal.noChord) }
        let focused = try focusedElement ?? guarded("finding the focused field") { try api.element(kAXFocusedUIElementAttribute, of: app) }
        guard let focused else {
            throw RunnerFailure(code: RunnerFailure.Code.nothingFocused, message: "nothing has keyboard focus")
        }
        guard api.set(kAXValueAttribute, of: focused, to: .string("")) else {
            throw RunnerFailure(code: RunnerFailure.Code.internal, message: "the field would not take an empty value")
        }
    }

    /// A direction swipe with no element: the content window's first scroll area, in the direction the points imply.
    public func drag(from: ScreenPoint, to: ScreenPoint, duration: Double) throws {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let direction: SwipeDirection = abs(dy) >= abs(dx) ? (dy < 0 ? .up : .down) : (dx < 0 ? .left : .right)
        let area = try guarded("looking for a scroll area") { try lastScene?.mainWindow.flatMap { try firstScrollArea(under: $0, depth: 0) } }
        guard let area else {
            throw RunnerFailure(code: RunnerFailure.Code.notFound, message: "the window has no scroll area to scroll; \(Refusal.noDrag)")
        }
        try guarded("scrolling") { try scrollArea(area, direction: direction) }
    }

    public func scroll(node: FlatNode, direction: SwipeDirection) throws -> Bool {
        var element = try element(of: node)
        for _ in 0..<MacSnapshot.maxDepth {
            if try guarded("scrolling", { try api.string(kAXRoleAttribute, of: element) }) == "AXScrollArea" {
                try guarded("scrolling") { try scrollArea(element, direction: direction) }
                return true
            }
            guard let parent = try guarded("scrolling", { try api.element(kAXParentAttribute, of: element) }) else { break }
            element = parent
        }
        throw RunnerFailure(code: RunnerFailure.Code.notHittable, message: "no scroll area encloses it", frame: node.frame)
    }

    func firstScrollArea(under element: AXElement, depth: Int) throws -> AXElement? {
        if try api.string(kAXRoleAttribute, of: element) == "AXScrollArea" { return element }
        guard depth < MacSnapshot.maxDepth else { return nil }
        for child in try api.elements(kAXChildrenAttribute, of: element) {
            if let found = try firstScrollArea(under: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Moves the area's scroll bar one page: the visible share of the content, or a quarter when the content's size
    /// is not readable. `up` moves the content up, towards its end, as a swipe up does on a simulator.
    func scrollArea(_ area: AXElement, direction: SwipeDirection) throws {
        let vertical = direction == .up || direction == .down
        guard let bar = try api.element(vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute, of: area) else {
            throw RunnerFailure(code: RunnerFailure.Code.notHittable, message: "the scroll area has no \(vertical ? "vertical" : "horizontal") scroll bar")
        }
        let visible = try api.rect(of: area)
        let content = try api.elements(kAXChildrenAttribute, of: area).first { try api.string(kAXRoleAttribute, of: $0) != "AXScrollBar" }
        let extent = try content.flatMap { try api.rect(of: $0) }
        var page = 0.25
        if let visible, let extent, extent.w > 0, extent.h > 0 {
            page = min(1, vertical ? visible.h / extent.h : visible.w / extent.w)
        }
        let current = try api.number(kAXValueAttribute, of: bar) ?? 0
        let next = min(1, max(0, current + (direction == .up || direction == .left ? page : -page)))
        guard api.set(kAXValueAttribute, of: bar, to: .number(next)) else {
            throw RunnerFailure(code: RunnerFailure.Code.internal, message: "the scroll bar would not take a new value")
        }
    }
}
