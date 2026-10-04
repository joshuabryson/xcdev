import Foundation

public struct ScreenshotReport: Reportable {
    public let device: String
    public let udid: String
    public let path: String
    public let width: Int?
    public let height: Int?
    /// Pixels per point: frames from `xcd ui tree` × scale = pixels in this image.
    public let scale: Double?
    public let worktree: String

    public var text: String {
        var line = "screenshot \(device)  path=\(path)"
        if let width, let height { line += "  \(width)x\(height)px" }
        if let scale { line += "  @\(scale.formatted(.number.precision(.fractionLength(0...1))))x" }
        return line
    }

    public var envelopeWorktree: String? { worktree }
}

public struct RecordingReport: Reportable {
    public enum Action: String, Codable, Sendable {
        case started, stopped
        case notRecording = "not_recording"
    }

    public let action: Action
    public let device: String
    public let udid: String?
    public let path: String?
    public let seconds: Double?
    public let bytes: Int64?
    public let outcome: DetachedStop?
    /// `ui.record.maxDuration` as text, when starting.
    public let limit: String?
    public let worktree: String

    public var text: String {
        switch action {
        case .notRecording:
            return "\(device) isn't recording; nothing to stop"
        case .started:
            return "recording \(device)  path=\(path ?? "")\n"
                + "next: stop it with `xcd ui record stop` (a recording longer than \(limit ?? "10m") is stopped by the next xcd command)"
        case .stopped:
            var lines = ["stopped recording \(device)  path=\(path ?? "")"
                + (seconds.map { "  duration=\(DurationText.format(.milliseconds(Int64($0 * 1000))))" } ?? "")
                + (bytes.map { "  size=\(ByteText.format($0))" } ?? "")]
            if outcome == .killed {
                lines.append("warning: simctl didn't finish within \(DurationText.format(MediaService.stopTimeout)) and was killed, so the video may be incomplete")
            } else if outcome == .notRunning {
                lines.append("note: the recording had already ended on its own")
            }
            if bytes == 0 { lines.append("warning: the video file is empty") }
            return lines.joined(separator: "\n")
        }
    }

    public var envelopeWorktree: String? { worktree }
}
