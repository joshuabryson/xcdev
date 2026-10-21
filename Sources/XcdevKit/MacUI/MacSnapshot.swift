import ApplicationServices
import Foundation

/// What one read of the app's Accessibility tree found.
public struct MacScene {
    public var root: SnapshotNode
    public var windows: [AXElement]
    public var mainWindow: AXElement?
    /// The main window's title, for the tree header: the window itself is a structural node the default tree leaves out.
    public var mainTitle: String
    public var hidden: Bool
    /// Whether the depth or node cap cut the tree short.
    public var capped: Bool
}

/// Reads an app's windows and open menus into the engine's node tree.
public struct MacSnapshot {
    public static let maxDepth = 40
    /// The most nodes one tree holds, the root included.
    public static let maxNodes = 5000
    let api: any AccessibilityAPI

    public init(api: any AccessibilityAPI) { self.api = api }

    /// A walk in progress: the window's origin that frames are measured from, and the nodes used so far.
    final class Walk {
        var origin = ScreenPoint(x: 0, y: 0)
        /// The root is the first.
        var nodes = 1
        var capped = false

        /// Whether one more node fits under the cap. When it does not, the walk is capped: something was left out.
        func admitsAnother() -> Bool {
            if nodes < MacSnapshot.maxNodes { return true }
            capped = true
            return false
        }
    }

    /// The root is the application. Its children are the windows in `AXWindows` order, each walked with frames in its
    /// own coordinates, then the menus the application element lists itself (pop-up menus), measured from the main
    /// window. A context menu sits under the cell it opened on, so the window walk finds it. The menu bar is not read.
    public func read(app: AXElement) throws -> MacScene {
        let windows = try api.elements(kAXWindowsAttribute, of: app)
        let main = try api.element(kAXMainWindowAttribute, of: app) ?? windows.first
        let walk = Walk()
        var children: [SnapshotNode] = []
        for window in windows {
            guard walk.admitsAnother() else { break }
            walk.origin = try origin(of: window)
            children.append(try node(window, depth: 1, parentType: 2, walk: walk))
        }
        walk.origin = try main.map(origin(of:)) ?? ScreenPoint(x: 0, y: 0)
        for menu in try menus(of: app) {
            guard walk.admitsAnother() else { break }
            children.append(try node(menu, depth: 1, parentType: 2, walk: walk))
        }
        let size = try main.flatMap { try api.rect(of: $0) } ?? ScreenRect(x: 0, y: 0, w: 0, h: 0)
        let title = try main.flatMap { try api.string(kAXTitleAttribute, of: $0) } ?? ""
        let root = SnapshotNode(elementType: 2, identifier: "", label: "", value: nil, placeholder: nil,
                                frame: ScreenRect(x: 0, y: 0, w: size.w, h: size.h), enabled: true, selected: false, children: children,
                                handle: String(app.token))
        return MacScene(root: root, windows: windows, mainWindow: main, mainTitle: title,
                        hidden: try api.bool(kAXHiddenAttribute, of: app) ?? false, capped: walk.capped)
    }

    func origin(of window: AXElement) throws -> ScreenPoint {
        try api.rect(of: window).map { ScreenPoint(x: $0.x, y: $0.y) } ?? ScreenPoint(x: 0, y: 0)
    }

    /// The application's own children that are menus: not its windows, and not its menu bar.
    func menus(of app: AXElement) throws -> [AXElement] {
        try api.elements(kAXChildrenAttribute, of: app).filter { try api.string(kAXRoleAttribute, of: $0) == "AXMenu" }
    }

    func node(_ element: AXElement, depth: Int, parentType: Int, walk: Walk) throws -> SnapshotNode {
        walk.nodes += 1
        let role = try api.string(kAXRoleAttribute, of: element) ?? "AXUnknown"
        let type = MacRoles.elementType(role: role, subrole: try api.string(kAXSubroleAttribute, of: element), parentType: parentType)
        let value = try api.string(kAXValueAttribute, of: element)
        let children = try children(of: element, depth: depth, type: type, walk: walk)
        return SnapshotNode(elementType: type, identifier: try api.string(kAXIdentifierAttribute, of: element) ?? "",
                            label: try label(of: element, type: type, value: value), value: value,
                            placeholder: try api.string(kAXPlaceholderValueAttribute, of: element), frame: try frame(of: element, in: walk),
                            enabled: try api.bool(kAXEnabledAttribute, of: element) ?? true,
                            selected: try api.bool(kAXSelectedAttribute, of: element) ?? false, children: children,
                            focused: try api.bool(kAXFocusedAttribute, of: element) ?? false, handle: String(element.token))
    }

    /// The element's children, until the depth or the node cap; any child left out marks the walk capped.
    func children(of element: AXElement, depth: Int, type: Int, walk: Walk) throws -> [SnapshotNode] {
        let elements = try api.elements(kAXChildrenAttribute, of: element)
        guard depth < Self.maxDepth else {
            if !elements.isEmpty { walk.capped = true }
            return []
        }
        var children: [SnapshotNode] = []
        for child in elements {
            guard walk.admitsAnother() else { break }
            children.append(try node(child, depth: depth + 1, parentType: type, walk: walk))
        }
        return children
    }

    func label(of element: AXElement, type: Int, value: String?) throws -> String {
        if let title = try api.string(kAXTitleAttribute, of: element), !title.isEmpty { return title }
        if let description = try api.string(kAXDescriptionAttribute, of: element), !description.isEmpty { return description }
        return type == 48 ? (value ?? "") : ""
    }

    /// The element's frame in its window's coordinates; a frame the app does not give is empty at the origin.
    func frame(of element: AXElement, in walk: Walk) throws -> ScreenRect {
        guard let rect = try api.rect(of: element), rect.w > 0, rect.h > 0 else { return ScreenRect(x: 0, y: 0, w: 0, h: 0) }
        return ScreenRect(x: rect.x - walk.origin.x, y: rect.y - walk.origin.y, w: rect.w, h: rect.h)
    }
}
