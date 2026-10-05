import Foundation

enum UIText {
    static let restartNote = "note: the UI runner was restarted, so refs from earlier trees are gone"

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

/// `xcd ui tree`.
public struct UITreeReport: Reportable {
    public let device: String
    public let udid: String
    public let restarted: Bool
    public let tree: TreeResult
    public let worktree: String

    public var text: String {
        let subject: String
        switch tree.state {
        case "system": subject = "springboard"
        case "foreground": subject = "app \(tree.bundleId ?? "") (foreground)"
        case "background": subject = "app \(tree.bundleId ?? "") (background; showing Springboard)"
        default: subject = "app \(tree.bundleId ?? "") (not running; showing Springboard)"
        }
        let header = "\(subject)  screen \(ScreenRect.number(tree.screen.w))x\(ScreenRect.number(tree.screen.h))pt "
            + "@\(ScreenRect.number(tree.scale))x  \(tree.orientation)  keyboard: \(tree.keyboard ? "shown" : "hidden")"
        var lines = [header] + UIText.rows(tree.elements)
        if tree.elements.isEmpty { lines.append("(no elements; `xcd ui tree --all` shows containers and off-screen elements)") }
        if restarted { lines.append(UIText.restartNote) }
        if tree.state == "not_running" { lines.append("next: start the app with `xcd run` or `xcd launch`") }
        return lines.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktree }
}

/// `xcd ui tap` (and, later, the other actions).
public struct UIActionReport: Reportable {
    public let action: String
    public let target: String
    public let element: TreeElement?
    public let x: Double?
    public let y: Double?
    public let ms: Int
    public let restarted: Bool
    public let device: String
    public let udid: String
    public let worktree: String

    public var text: String {
        let point = x.flatMap { x in y.map { " at \(ScreenRect.number(x)),\(ScreenRect.number($0))" } } ?? ""
        var lines = ["\(action) \(element.map(UIText.name) ?? target)\(element == nil ? "" : point)  \(ms)ms"]
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
    public let rebuild: Bool
    public let worktree: String

    public var text: String {
        var lines = stopped.isEmpty ? ["no UI runner was running for \(device)"] : stopped
        if rebuild { lines.append("the UI runner will be rebuilt on next use") }
        return lines.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktree }
}
