import Foundation

/// What identifies an element between two snapshots: its role, identifier, label, source, and its path of
/// (elementType, position) pairs from the root. The path identifies the element even when unrelated siblings appear.
/// Computed over the whole snapshot, so the default filter can't shift it.
public struct RefSignature: Codable, Sendable, Equatable, Hashable {
    public var role: String
    public var identifier: String
    public var label: String
    public var path: [Int]
    public var source: ElementSource

    public init(role: String, identifier: String, label: String, path: [Int], source: ElementSource) {
        self.role = role
        self.identifier = identifier
        self.label = label
        self.path = path
        self.source = source
    }
}

/// A snapshot element in flattened (depth-first) order.
public struct FlatNode: Sendable, Equatable {
    public var role: String
    public var identifier: String
    public var label: String
    public var value: String?
    public var placeholder: String?
    public var frame: ScreenRect
    public var enabled: Bool
    public var selected: Bool
    public var depth: Int
    public var source: ElementSource
    /// Index of the parent in the flat list.
    public var parent: Int?
    public var signature: RefSignature
    public var inKeyboard: Bool
    public var window: Int

    public var isInteractive: Bool { ElementRole.interactive.contains(role) }
    public var hasText: Bool { !label.isEmpty || !(value ?? "").isEmpty }
}

/// Where an element sits in the snapshot being flattened.
private struct TreePosition {
    var depth: Int
    /// Index of the parent in the flat list.
    var parent: Int?
    var path: [Int]
    var inKeyboard: Bool
    var window: Int
}

/// One depth-first walk of a snapshot, appending to `nodes`.
private struct TreeWalk {
    let source: ElementSource
    var nodes: [FlatNode]
    /// The number of the last window met; -1 before the first.
    var windows = -1

    mutating func visit(_ node: SnapshotNode, at position: TreePosition) {
        let role = ElementRole.name(for: node.elementType)
        var window = position.window
        if role == "window" {
            windows += 1
            window = windows
        }
        // An empty text field reports its placeholder as its value.
        let value = node.placeholder != nil && node.value == node.placeholder ? "" : node.value
        let index = nodes.count
        let signature = RefSignature(role: role, identifier: node.identifier, label: node.label, path: position.path, source: source)
        nodes.append(FlatNode(role: role, identifier: node.identifier, label: node.label, value: value, placeholder: node.placeholder,
                              frame: TreeBuilder.finite(node.frame), enabled: node.enabled, selected: node.selected, depth: position.depth,
                              source: source, parent: position.parent, signature: signature, inKeyboard: position.inKeyboard, window: window))
        var seen: [Int: Int] = [:]
        for child in node.children {
            let place = seen[child.elementType, default: 0]
            seen[child.elementType] = place + 1
            visit(child, at: TreePosition(depth: position.depth + 1, parent: index, path: position.path + [child.elementType, place],
                                          inKeyboard: position.inKeyboard || role == "keyboard", window: window))
        }
    }
}

public enum TreeBuilder {
    /// Appends `root` and its descendants to `nodes`, depth first.
    public static func flatten(_ root: SnapshotNode, source: ElementSource, into nodes: inout [FlatNode]) {
        var walk = TreeWalk(source: source, nodes: [])
        swap(&walk.nodes, &nodes)                       // the walk appends in place, without copying what is already there
        walk.visit(root, at: TreePosition(depth: 0, parent: nil, path: [root.elementType, 0], inKeyboard: false, window: 0))
        swap(&walk.nodes, &nodes)
    }

    /// A frame with every non-finite component replaced by 0, so it is empty or off screen and can be encoded.
    static func finite(_ frame: ScreenRect) -> ScreenRect {
        func clean(_ value: Double) -> Double { value.isFinite ? value : 0 }
        return ScreenRect(x: clean(frame.x), y: clean(frame.y), w: clean(frame.w), h: clean(frame.h))
    }

    /// The frame isn't empty and its centre is on the screen.
    public static func isOnScreen(_ node: FlatNode, screen: ScreenRect) -> Bool {
        !node.frame.isEmpty && screen.contains(x: node.frame.midX, y: node.frame.midY)
    }

    /// Whether an ancestor of `nodes[index]` satisfies `test`.
    public static func hasAncestor(_ index: Int, in nodes: [FlatNode], where test: (FlatNode) -> Bool) -> Bool {
        var current = nodes[index].parent
        while let i = current {
            if test(nodes[i]) { return true }
            current = nodes[i].parent
        }
        return false
    }

    /// Indices of the elements `xcd ui tree` shows. With `all`, every element. By default: on screen, not in the
    /// keyboard, and either interactive or a non-container with something to aim at (`isWorthShowing`).
    public static func displayed(_ nodes: [FlatNode], screen: ScreenRect, all: Bool) -> [Int] {
        if all { return Array(nodes.indices) }
        return nodes.indices.filter { index in
            let node = nodes[index]
            guard isOnScreen(node, screen: screen), !node.inKeyboard, node.role != "keyboard" else { return false }
            if node.isInteractive { return true }
            return !ElementRole.structural.contains(node.role) && isWorthShowing(index, in: nodes)
        }
    }

    /// Whether a non-interactive, non-container element gives an agent something to aim at: a label or value, unless
    /// it only repeats the label of an interactive ancestor (a button's own text); or else an identifier, unless an
    /// ancestor carries the same one (SwiftUI copies a container's identifier to its children).
    static func isWorthShowing(_ index: Int, in nodes: [FlatNode]) -> Bool {
        let node = nodes[index]
        if node.hasText {
            return !hasAncestor(index, in: nodes) { $0.isInteractive && !$0.label.isEmpty && $0.label == node.label }
        }
        return !node.identifier.isEmpty && !hasAncestor(index, in: nodes) { $0.identifier == node.identifier }
    }

    public static func element(_ node: FlatNode, ref: String?, screen: ScreenRect) -> TreeElement {
        TreeElement(ref: ref, role: node.role, label: node.label, identifier: node.identifier, value: node.value,
                    placeholder: node.placeholder, frame: node.frame, depth: node.depth, enabled: node.enabled,
                    selected: node.selected, source: node.source, offscreen: !isOnScreen(node, screen: screen), window: node.window)
    }
}
