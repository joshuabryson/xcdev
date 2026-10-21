import Foundation

enum UIText {
    static let restartNote = "note: the UI runner was restarted, so refs from earlier trees are gone"
    static let treeUnreadNote = "note: the tree could not be read after the action; run `xcd ui tree`"

    /// `button "Sign In" id=signIn`, the short form used in action and wait reports.
    static func name(_ element: TreeElement) -> String {
        var parts = [element.role, element.label.isEmpty ? "(no label)" : "\"\(element.label)\""]
        if !element.identifier.isEmpty { parts.append("id=\(element.identifier)") }
        return parts.joined(separator: " ")
    }

    /// The tree's rows: ref, role, label, value, placeholder, id, frame, then flags. The ref and role columns are
    /// padded to the widest entry plus two spaces; the rest are separated by two spaces.
    static func rows(_ elements: [TreeElement]) -> [String] {
        let refWidth = (elements.map { ($0.ref ?? "-").count }.max() ?? 1) + 2
        let roleWidth = (elements.map(\.role.count).max() ?? 0) + 2
        return elements.map { element in
            var parts = [element.label.isEmpty ? "(no label)" : "\"\(element.label)\""]
            if let value = element.value { parts.append("value=\"\(value)\"") }
            if let placeholder = element.placeholder { parts.append("placeholder=\"\(placeholder)\"") }
            if !element.identifier.isEmpty { parts.append("id=\(element.identifier)") }
            parts.append(element.frame.text)
            if !element.enabled { parts.append("disabled") }
            if element.selected { parts.append("selected") }
            if element.offscreen { parts.append("offscreen") }
            if element.source == .system { parts.append("system") }
            return (element.ref ?? "-").padding(toLength: refWidth, withPad: " ", startingAt: 0)
                + element.role.padding(toLength: roleWidth, withPad: " ", startingAt: 0) + parts.joined(separator: "  ")
        }
    }
}

extension UIText {
    static let cappedNote = "note: the tree was capped (5000 nodes or depth 40); the rest is not listed"
    static let noWindowNext = "next: the app has no window; open one with `xcd open <route>`, or watch it with `xcd launch --show`"

    /// The tree's header line and its rows, as `xcd ui tree` and an action with `--tree` print them. A Mac's tree
    /// (`hidden` is set) has its own header; one of an app with no window has no rows to explain.
    static func tree(_ tree: TreeResult) -> [String] {
        var lines = [tree.hidden == nil ? header(tree) : macHeader(tree)] + UIText.rows(tree.elements)
        if tree.elements.isEmpty, tree.windows != 0 { lines.append("(no elements; `xcd ui tree --all` shows containers and off-screen elements)") }
        if tree.capped == true { lines.append(cappedNote) }
        return lines
    }

    static func header(_ tree: TreeResult) -> String {
        let subject: String
        switch tree.state {
        case "system": subject = "springboard"
        case "foreground": subject = "app \(tree.bundleId ?? "") (foreground)"
        case "background": subject = "app \(tree.bundleId ?? "") (background; showing Springboard)"
        default: subject = "app \(tree.bundleId ?? "") (not running; showing Springboard)"
        }
        return "\(subject)  screen \(ScreenRect.number(tree.screen.w))x\(ScreenRect.number(tree.screen.h))pt "
            + "@\(ScreenRect.number(tree.scale))x  \(tree.orientation)  keyboard: \(tree.keyboard ? "shown" : "hidden")"
    }

    /// `running (hidden)  window: Probe 900x552 @2x`: the window node itself is structural and not in the default
    /// tree, so its title is here; the size is the main window's, which frames are measured in.
    static func macHeader(_ tree: TreeResult) -> String {
        let state = "running (\(tree.hidden == true ? "hidden" : "visible"))"
        guard tree.windows != 0 else { return state + "  no windows" }
        let title = tree.windowTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "untitled"
        let size = "\(ScreenRect.number(tree.screen.w))x\(ScreenRect.number(tree.screen.h))"
        let count = tree.windows.flatMap { $0 > 1 ? "  windows: \($0)" : nil } ?? ""
        return "\(state)  window: \(title) \(size) @\(ScreenRect.number(tree.scale))x" + count
    }
}

/// `xcd ui tree`.
public struct UITreeReport: Reportable {
    public let device: String
    public let udid: String
    public let restarted: Bool
    public let tree: TreeResult
    public let worktree: String

    public var text: String {
        var lines = UIText.tree(tree)
        if restarted { lines.append(UIText.restartNote) }
        if tree.state == "not_running" { lines.append("next: start the app with `xcd run` or `xcd launch`") }
        if tree.state == "background" { lines.append("next: bring it forward with `xcd launch`, or act on the Home Screen with `--system`") }
        if tree.hidden != nil, tree.windows == 0 { lines.append(UIText.noWindowNext) }
        return lines.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktree }
}

/// `xcd ui tap`, `long-press`, `swipe`, `type`, `button`, and `rotate`.
public struct UIActionReport: Reportable {
    /// What was done, up to its object: "tapped", "swiped up on", "typed 5 characters into".
    public let action: String
    /// The target as given, or what stands in for one ("the screen", "home").
    public let target: String
    public let element: TreeElement?
    public let x: Double?
    public let y: Double?
    public let ms: Int
    public let restarted: Bool
    public let device: String
    public let udid: String
    public let worktree: String
    /// Where a swipe ended.
    public var toX: Double?
    public var toY: Double?
    /// How text was entered: "keyboard" or "paste".
    public var method: String?
    /// What follows the object in the text: "for 1.0s", "to 201,87", "by keyboard, then Return".
    public var detail: String?
    /// The tree after the action (`--tree`).
    public var tree: TreeResult?
    public var notes: [String] = []

    public var text: String {
        var line = "\(action) \(element.map(UIText.name) ?? target)"
        if element != nil, let x, let y { line += " at \(ScreenRect.number(x)),\(ScreenRect.number(y))" }
        if let detail { line += " \(detail)" }
        var lines = [line + "  \(ms)ms"]
        if let tree { lines += UIText.tree(tree) }
        lines += notes
        if restarted { lines.append(UIText.restartNote) }
        return lines.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktree }
}

/// `xcd ui wait`.
public struct UIWaitReport: Reportable {
    public let target: String
    public let gone: Bool
    public let element: TreeElement?
    public let ms: Int
    public let restarted: Bool
    public let device: String
    public let udid: String
    public let worktree: String

    public var text: String {
        var lines = [gone ? "\(target) is gone after \(ms)ms" : "found \(element.map(UIText.name) ?? target) after \(ms)ms"]
        if restarted { lines.append(UIText.restartNote) }
        return lines.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktree }
}

/// `xcd ui stop`.
public struct UIStopReport: Reportable {
    public let device: String
    public let stopped: [String]
    /// `--rebuild` as given; on a Mac, where it does nothing, `stopped` says so.
    public let rebuild: Bool
    public let worktree: String

    static let macRebuildNote = "--rebuild does nothing on a Mac"

    public var text: String {
        var lines = stopped.isEmpty ? ["no UI runner was running for \(device)"] : stopped
        if rebuild, !stopped.contains(Self.macRebuildNote) { lines.append("the UI runner will be rebuilt on next use") }
        return lines.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktree }
}

/// `xcd ui menu`.
public struct UIMenuReport: Reportable {
    public let device: String
    public let items: [MacMenuItem]?
    public let pressed: String?
    /// The tree after the press (`--tree`).
    public var tree: TreeResult?
    public let worktree: String
    /// Says when `--tree` was asked and the tree could not be read after the press.
    public var notes: [String] = []

    public var text: String {
        if let items {
            return items.isEmpty ? "the app has no menu bar items" : items.map { $0.path + ($0.enabled ? "" : " (disabled)") }.joined(separator: "\n")
        }
        var lines = ["pressed \(pressed ?? "")"]
        if let tree { lines += UIText.tree(tree) }
        lines += notes
        return lines.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktree }
}
