import Foundation

/// `xcd sim fold`.
public struct PostureReport: Reportable {
    public let device: String
    public let udid: String
    /// `closed`, `half`, `open`, or `open or half` when only the display is known.
    public let posture: String
    public let angle: Double?
    /// `cover` or `inner`.
    public let display: String
    /// The pose's own word, nil when devicectl's word was not in the table.
    public let orientation: String?
    /// The route that delivered the request; nil when nothing was sent.
    public let route: String?
    /// True when a witness named the requested state or angle, or when nothing was asked.
    public let verified: Bool
    /// True when the device already was as asked, so nothing was sent.
    public let already: Bool
    public let worktree: String

    public var text: String {
        var line = "posture: \(posture)"
        if let angle { line += " (\(Int(angle.rounded()))°)" }
        line += "  display: \(display)"
        if let orientation { line += "  orientation: \(orientation)" }
        if let route { line += "  route: \(route)" }
        if already { line += "  (already there, nothing sent)" }
        if !verified { line += "  unverified: the display agrees but no DCMPose line confirmed it" }
        return line
    }

    public var envelopeWorktree: String? { worktree }
}
