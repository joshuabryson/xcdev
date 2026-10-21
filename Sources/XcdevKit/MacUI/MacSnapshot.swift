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

    /// The role of the menu bar, which `ui menu` lists and the tree never holds.
    static let menuBarRole = "AXMenuBar"

    /// A walk in progress: the window's origin that frames are measured from, the nodes used so far, and the path.
    final class Walk {
        var origin = ScreenPoint(x: 0, y: 0)
        /// The root is the first.
        var nodes = 1
        var capped = false
        /// The application and the elements from the top of the walk down to the element being read. A child that is
        /// one of them loops back up the tree (a locked screen lists the application under itself) and is not read.
        var path: Set<AXElement>

        init(app: AXElement) { path = [app] }

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
    /// A window or an element that goes away during the walk is left out; a failure on the application itself, or on
    /// the main window once chosen, is the read's.
    public func read(app: AXElement) throws -> MacScene {
        let windows = try windows(of: app)
        let main = try mainWindow(of: app, windows: windows)
        let walk = Walk(app: app)
        var children = try topNodes(windows, walk: walk) { try origin(of: $0) }
        let mainOrigin = try main.map(origin(of:)) ?? ScreenPoint(x: 0, y: 0)
        children += try topNodes(menus(of: app), walk: walk) { _ in mainOrigin }
        let size = try main.flatMap { try api.rect(of: $0) } ?? ScreenRect(x: 0, y: 0, w: 0, h: 0)
        let title = try main.flatMap { try api.string(kAXTitleAttribute, of: $0) } ?? ""
        let root = SnapshotNode(elementType: 2, identifier: "", label: "", value: nil, placeholder: nil,
                                frame: ScreenRect(x: 0, y: 0, w: size.w, h: size.h), enabled: true, selected: false, children: children,
                                handle: String(app.token))
        return MacScene(root: root, windows: windows, mainWindow: main, mainTitle: title,
                        hidden: try api.bool(kAXHiddenAttribute, of: app) ?? false, capped: walk.capped)
    }

    /// The root's children: each window or menu walked with frames from the origin `origin` gives it, until the node cap.
    func topNodes(_ elements: [AXElement], walk: Walk, origin: (AXElement) throws -> ScreenPoint) throws -> [SnapshotNode] {
        var nodes: [SnapshotNode] = []
        for element in elements {
            guard walk.admitsAnother() else { break }
            let node = try surviving {
                walk.origin = try origin(element)
                return try self.node(element, depth: 1, parentType: 2, walk: walk)
            }
            if let node { nodes.append(node) }
        }
        return nodes
    }

    /// What `read` gives, or nil when the element it reads went away meanwhile: an app that rebuilds its content (a
    /// SwiftUI app right after a link, measured 2026-10-20) drops elements under the walk, and the rest is still right.
    func surviving<T>(_ read: () throws -> T?) throws -> T? {
        do {
            return try read()
        } catch MacAXError.elementGone {
            return nil
        }
    }

    /// The title of the window `read(app:)` calls main, without walking the tree, or nil when the app has no window: the
    /// window a screenshot or a recording takes is the one ScreenCaptureKit lists under this title.
    public func mainTitle(app: AXElement) throws -> String? {
        try mainWindow(of: app, windows: windows(of: app)).map { try api.string(kAXTitleAttribute, of: $0) ?? "" }
    }

    /// `AXWindows`, without the application itself, which a locked screen lists there.
    func windows(of app: AXElement) throws -> [AXElement] {
        try api.elements(kAXWindowsAttribute, of: app).filter { $0 != app }
    }

    /// The window with the app's content. A link opened on a hidden SwiftUI app adds an empty twin that becomes
    /// `AXMainWindow` while the controls stay in the other. So: `AXMainWindow` when it holds anything, else
    /// the first window that does, else `AXMainWindow`, else the first window.
    func mainWindow(of app: AXElement, windows: [AXElement]) throws -> AXElement? {
        let named = try api.element(kAXMainWindowAttribute, of: app).flatMap { $0 == app ? nil : $0 }    // a locked screen's answer
        if let named, try holdsContent(named, app: app) { return named }
        return try windows.first { try holdsContent($0, app: app) } ?? named ?? windows.first
    }

    /// Whether the window holds anything besides window chrome: the first element of any role that is neither a window,
    /// a title-bar button, nor the menu bar counts at once, and the search goes down only through windows and title-bar
    /// buttons. An empty twin lists only its close, minimize, and zoom buttons. A window that is gone holds nothing.
    func holdsContent(_ window: AXElement, app: AXElement) throws -> Bool {
        try surviving { try holdsContent(window, depth: 1, walk: Walk(app: app)) } ?? false
    }

    /// The search skips what the walk skips (loops back up the tree, the menu bar, an element that went away) and stops
    /// at the same caps.
    func holdsContent(_ element: AXElement, depth: Int, walk: Walk) throws -> Bool {
        guard depth < Self.maxDepth else { return false }
        walk.path.insert(element)
        defer { walk.path.remove(element) }
        for child in try api.elements(kAXChildrenAttribute, of: element) where !walk.path.contains(child) {
            guard walk.admitsAnother() else { return false }
            walk.nodes += 1
            if try surviving({ try isContent(child, depth: depth, walk: walk) }) == true { return true }
        }
        return false
    }

    /// Whether a child of an element at `depth` is content, or holds some below it; the menu bar is neither.
    func isContent(_ child: AXElement, depth: Int, walk: Walk) throws -> Bool {
        let role = try api.string(kAXRoleAttribute, of: child) ?? "AXUnknown"
        if role == Self.menuBarRole { return false }
        if !MacRoles.isWindowChrome(role: role, subrole: try api.string(kAXSubroleAttribute, of: child)) { return true }
        return try holdsContent(child, depth: depth + 1, walk: walk)
    }

    func origin(of window: AXElement) throws -> ScreenPoint {
        try api.rect(of: window).map { ScreenPoint(x: $0.x, y: $0.y) } ?? ScreenPoint(x: 0, y: 0)
    }

    /// The application's own children that are menus: not its windows, not its menu bar, and not one that went away.
    func menus(of app: AXElement) throws -> [AXElement] {
        try api.elements(kAXChildrenAttribute, of: app).filter { child in try surviving { try api.string(kAXRoleAttribute, of: child) } == "AXMenu" }
    }

    /// The element as a node, with its children; nil for a menu bar, which is `ui menu`'s and never the tree's.
    func node(_ element: AXElement, depth: Int, parentType: Int, walk: Walk) throws -> SnapshotNode? {
        let role = try api.string(kAXRoleAttribute, of: element) ?? "AXUnknown"
        guard role != Self.menuBarRole else { return nil }
        walk.nodes += 1
        walk.path.insert(element)
        defer { walk.path.remove(element) }
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

    /// The element's children, until the depth or the node cap; any child left out marks the walk capped. A child that
    /// is the application or an element on the path down to this one is a loop, not a child, and is skipped; so is one
    /// that went away while it was read.
    func children(of element: AXElement, depth: Int, type: Int, walk: Walk) throws -> [SnapshotNode] {
        let elements = try api.elements(kAXChildrenAttribute, of: element).filter { !walk.path.contains($0) }
        guard depth < Self.maxDepth else {
            if !elements.isEmpty { walk.capped = true }
            return []
        }
        var children: [SnapshotNode] = []
        for child in elements {
            guard walk.admitsAnother() else { break }
            if let node = try surviving({ try node(child, depth: depth + 1, parentType: type, walk: walk) }) { children.append(node) }
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
