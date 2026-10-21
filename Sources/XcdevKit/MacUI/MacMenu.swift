import ApplicationServices
import Foundation

public struct MacMenuItem: Sendable, Equatable, Codable {
    public let path: String
    public let enabled: Bool
}

/// The app's menu bar through the Accessibility API: paths like `File > Save…`, three levels deep,
/// Services left out, and a press by path. `...` and `…` match each other.
public struct MacMenu {
    public static let maxDepth = 3
    let api: any AccessibilityAPI
    let app: AXElement

    public init(api: any AccessibilityAPI, app: AXElement) {
        self.api = api
        self.app = app
    }

    /// A menu-bar item, or an item with a submenu, and what it holds.
    struct Node {
        let element: AXElement
        let title: String
        let enabled: Bool
    }

    func barItems() throws -> [Node] {
        let items = try api.element(kAXMenuBarAttribute, of: app).map { try api.elements(kAXChildrenAttribute, of: $0) }
            ?? api.elements(kAXMenuBarAttribute, of: app)
        return try items.compactMap { try node($0) }
    }

    func node(_ element: AXElement) throws -> Node? {
        guard let title = try api.string(kAXTitleAttribute, of: element), !title.isEmpty else { return nil }    // separators
        return Node(element: element, title: Self.normalized(title), enabled: try api.bool(kAXEnabledAttribute, of: element) ?? true)
    }

    /// The items of a menu-bar item or a submenu item: the children of its one `AXMenu` child.
    func children(of parent: Node) throws -> [Node] {
        guard let menu = try submenu(of: parent) else { return [] }
        return try api.elements(kAXChildrenAttribute, of: menu).compactMap { try node($0) }
    }

    /// The `AXMenu` a menu-bar item or an item with a submenu holds; nil for a plain item.
    func submenu(of parent: Node) throws -> AXElement? {
        try api.elements(kAXChildrenAttribute, of: parent.element).first(where: { try api.string(kAXRoleAttribute, of: $0) == "AXMenu" })
    }

    public func items() throws -> [MacMenuItem] {
        var found: [MacMenuItem] = []
        for bar in try barItems() { try collect(bar, path: bar.title, depth: 1, into: &found) }
        return found
    }

    func collect(_ node: Node, path: String, depth: Int, into found: inout [MacMenuItem]) throws {
        for child in try children(of: node) where child.title != "Services" {
            let childPath = path + " > " + child.title
            let below = depth < Self.maxDepth ? try children(of: child) : []
            if below.isEmpty { found.append(MacMenuItem(path: childPath, enabled: child.enabled)) } else { try collect(child, path: childPath, depth: depth + 1, into: &found) }
        }
    }

    public func press(path: String) throws -> MacMenuItem {
        let titles = path.split(separator: ">").map { Self.normalized($0.trimmingCharacters(in: .whitespaces)) }
        guard let first = titles.first, titles.count >= 2 else {
            throw XcdError(.usage, "'\(path)' is not a menu path", next: "write it as \"<Menu> > <Item>\", e.g. \"File > Save…\"")
        }
        let (node, walked) = try find(first, titles.dropFirst(), in: try barItems(), walked: [])
        guard try submenu(of: node) == nil else {
            throw XcdError(.elementNotHittable, "'\(path)' is a submenu, not an item", next: "name an item inside it, from `xcd ui menu`")
        }
        guard node.enabled else { throw XcdError(.elementNotHittable, "\(walked) is disabled", next: "do what enables it first") }
        guard api.perform(kAXPressAction, on: node.element) else { throw XcdError(.runnerFailed, "the app refused the press", next: "run `xcd ui tree`, then retry") }
        return MacMenuItem(path: walked, enabled: true)
    }

    /// Walks the titles down the menus: the item the last one names, and its path as the menus spell it.
    func find(_ title: String, _ rest: ArraySlice<String>, in current: [Node], walked: [String]) throws -> (node: Node, path: String) {
        guard let next = current.first(where: { $0.title == title }) else {
            throw XcdError(.elementNotFound, "no menu item \((walked + [title]).joined(separator: " > "))",
                           next: "run `xcd ui menu` to list the menu bar", details: current.map { (walked + [$0.title]).joined(separator: " > ") })
        }
        let path = walked + [next.title]
        guard let following = rest.first else { return (next, path.joined(separator: " > ")) }
        return try find(following, rest.dropFirst(), in: try children(of: next), walked: path)
    }

    static func normalized(_ title: String) -> String { title.replacingOccurrences(of: "...", with: "…") }
}
