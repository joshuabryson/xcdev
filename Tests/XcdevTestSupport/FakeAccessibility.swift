import ApplicationServices
import Foundation
import Synchronization
import XcdevKit

/// One element of a fake app's tree. Frames are screen coordinates, as the real API gives them.
public struct FakeNode: Sendable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var description: String?
    public var value: String?
    public var identifier: String?
    public var placeholder: String?
    public var frame: ScreenRect
    public var enabled = true
    public var selected = false
    public var focused = false
    public var actions: Set<String> = []
    public var children: [FakeNode] = []

    public init(role: String, subrole: String? = nil, title: String? = nil, description: String? = nil, value: String? = nil,
                identifier: String? = nil, placeholder: String? = nil, frame: ScreenRect, enabled: Bool = true, selected: Bool = false,
                focused: Bool = false, actions: Set<String> = [], children: [FakeNode] = []) {
        self.role = role; self.subrole = subrole; self.title = title; self.description = description; self.value = value
        self.identifier = identifier; self.placeholder = placeholder; self.frame = frame; self.enabled = enabled
        self.selected = selected; self.focused = focused; self.actions = actions; self.children = children
    }
}

public struct FakeApp: Sendable {
    public var windows: [FakeNode]
    /// Menus the application element lists among its own children, as a pop-up menu may be.
    public var menus: [FakeNode] = []
    /// The menu bar's items. The fake puts them under one `AXMenuBar` child of the application, as AX does.
    public var menuBar: [FakeNode] = []
    public var hidden = false
    public var running = true
    public var scale: Double = 2

    public init(windows: [FakeNode], menus: [FakeNode] = [], menuBar: [FakeNode] = [], hidden: Bool = false, scale: Double = 2) {
        self.windows = windows; self.menus = menus; self.menuBar = menuBar; self.hidden = hidden; self.scale = scale
    }
}

/// `AccessibilityAPI` over a `FakeApp`. Token 0 is the application; its windows, its menus, and its menu bar get the
/// tokens that follow, depth first, so a node's token is stable for the life of the fake.
public final class FakeAccessibility: AccessibilityAPI, Sendable {
    struct State {
        var app: FakeApp
        var nodes: [Int: FakeNode] = [:]
        var parents: [Int: Int] = [:]
        /// Each token's children's tokens, in order.
        var children: [Int: [Int]] = [:]
        var events: [String] = []
        var failing: Set<String> = []

        mutating func index(_ node: FakeNode, parent: Int) {
            let token = nodes.count + 1
            nodes[token] = node
            parents[token] = parent
            children[parent, default: []].append(token)
            for child in node.children { index(child, parent: token) }
        }
    }
    let state: Mutex<State>

    public init(app: FakeApp) {
        var initial = State(app: app)
        for window in app.windows { initial.index(window, parent: 0) }
        for menu in app.menus { initial.index(menu, parent: 0) }
        if !app.menuBar.isEmpty { initial.index(FakeNode(role: "AXMenuBar", frame: ScreenRect(x: 0, y: 0, w: 0, h: 0), children: app.menuBar), parent: 0) }
        state = Mutex(initial)
    }

    /// Every set, action, and key, in order, e.g. "AXPress increment", "set AXFocused name bool(true)", "key \"h\"".
    public var events: [String] { state.withLock { $0.events } }
    /// Identifiers whose reads throw `cannotComplete`, as a busy app's would.
    public var failing: Set<String> {
        get { state.withLock { $0.failing } }
        set { state.withLock { $0.failing = newValue } }
    }
    public func setRunning(_ running: Bool) { state.withLock { $0.app.running = running } }

    func node(_ element: AXElement) throws -> FakeNode? {
        try state.withLock { state in
            guard let node = state.nodes[element.token] else { return nil }
            if let id = node.identifier, state.failing.contains(id) { throw MacAXError.cannotComplete(id) }
            return node
        }
    }
    func children(of parent: Int) -> [AXElement] { state.withLock { ($0.children[parent] ?? []).map(AXElement.init(token:)) } }
    func windows() throws -> [AXElement] { try children(of: 0).filter { try node($0)?.role == "AXWindow" } }

    public var isTrusted: Bool { true }
    public var screenCaptureAllowed: Bool { true }
    public func isRunning(pid: Int32) -> Bool { state.withLock { $0.app.running } }
    public func application(pid: Int32) -> AXElement { AXElement(token: 0) }

    public func string(_ attribute: String, of element: AXElement) throws -> String? {
        if element.token == 0 { return attribute == kAXRoleAttribute ? "AXApplication" : nil }
        guard let node = try node(element) else { return nil }
        switch attribute {
        case kAXRoleAttribute: return node.role
        case kAXSubroleAttribute: return node.subrole
        case kAXTitleAttribute: return node.title
        case kAXDescriptionAttribute: return node.description
        case kAXValueAttribute: return node.value
        case kAXIdentifierAttribute: return node.identifier
        case kAXPlaceholderValueAttribute: return node.placeholder
        default: return nil
        }
    }

    public func bool(_ attribute: String, of element: AXElement) throws -> Bool? {
        if element.token == 0 { return attribute == kAXHiddenAttribute ? state.withLock { $0.app.hidden } : nil }
        guard let node = try node(element) else { return nil }
        switch attribute {
        case kAXEnabledAttribute: return node.enabled
        case kAXSelectedAttribute: return node.selected
        case kAXFocusedAttribute: return node.focused
        default: return nil
        }
    }

    public func number(_ attribute: String, of element: AXElement) throws -> Double? {
        attribute == kAXValueAttribute ? try node(element)?.value.flatMap { Double($0) } : nil
    }

    public func rect(of element: AXElement) throws -> ScreenRect? { try node(element)?.frame }

    public func element(_ attribute: String, of element: AXElement) throws -> AXElement? {
        switch attribute {
        case kAXMainWindowAttribute: return element.token == 0 ? try windows().first : nil
        case kAXMenuBarAttribute: return element.token == 0 ? try children(of: 0).first { try node($0)?.role == "AXMenuBar" } : nil
        case kAXParentAttribute: return state.withLock { $0.parents[element.token] }.map(AXElement.init(token:))
        case kAXFocusedUIElementAttribute: return state.withLock { $0.nodes.first { $0.value.focused }?.key }.map(AXElement.init(token:))
        case kAXVerticalScrollBarAttribute, kAXHorizontalScrollBarAttribute:
            let wanted = attribute == kAXVerticalScrollBarAttribute ? "AXVerticalScrollBar" : "AXHorizontalScrollBar"
            return try children(of: element.token).first { try node($0)?.role == "AXScrollBar" && node($0)?.subrole == wanted }
        default: return nil
        }
    }

    public func elements(_ attribute: String, of element: AXElement) throws -> [AXElement] {
        switch (attribute, element.token) {
        case (kAXWindowsAttribute, 0): return try windows()
        case (kAXChildrenAttribute, _): return children(of: element.token)
        default: return []
        }
    }

    public func set(_ attribute: String, of element: AXElement, to value: AXSettable) -> Bool {
        state.withLock { state in
            guard var node = state.nodes[element.token] else { return false }
            state.events.append("set \(attribute) \(node.identifier ?? node.title ?? "?") \(value)")
            switch (attribute, value) {
            case (kAXFocusedAttribute, .bool(let flag)):
                guard MacRoles.textEntry.contains(MacRoles.elementType(role: node.role, subrole: node.subrole)) || !flag else { return false }
                for key in state.nodes.keys { state.nodes[key]?.focused = false }
                node.focused = flag
            case (kAXValueAttribute, .string(let text)): node.value = text
            case (kAXValueAttribute, .number(let number)): node.value = String(number)
            default: return false
            }
            state.nodes[element.token] = node
            return true
        }
    }

    public func actions(of element: AXElement) -> [String] { ((try? node(element))?.actions).map(Array.init) ?? [] }

    public func perform(_ action: String, on element: AXElement) -> Bool {
        state.withLock { state in
            guard let node = state.nodes[element.token], node.actions.contains(action) else { return false }
            state.events.append("\(action) \(node.identifier ?? node.title ?? "?")")
            return true
        }
    }

    public func postKey(_ key: MacKey, to pid: Int32) {
        state.withLock { state in
            state.events.append("key \(key.text.map { $0.debugDescription } ?? String(key.code))")
            guard let focused = state.nodes.first(where: { $0.value.focused })?.key else { return }
            let current = state.nodes[focused]?.value ?? ""
            switch key.code {
            case 51: state.nodes[focused]?.value = String(current.dropLast())
            case 36: break
            default: state.nodes[focused]?.value = current + (key.text ?? "")
            }
        }
    }

    public func screenScale(containing rect: ScreenRect) -> Double { state.withLock { $0.app.scale } }
}
