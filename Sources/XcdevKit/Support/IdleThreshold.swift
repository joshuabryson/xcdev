import Foundation

/// How long a clone may go without an xcd command before it shuts itself down, in whole seconds; 0 is never.
public enum IdleThreshold {
    public static let defaultSeconds = 600

    /// "off" in any case is 0; a `DurationText` duration is whole seconds rounded up (500ms is 1); nil when unreadable.
    public static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed == "off" { return 0 }
        guard let duration = DurationText.parse(trimmed) else { return nil }
        return Int(DurationText.seconds(duration).rounded(.up))
    }

    /// `--idle`'s value: nil when not given; a `usage` error naming the flag when it can't be read.
    public static func option(_ text: String?) throws -> Int? {
        guard let text else { return nil }
        guard let seconds = parse(text) else {
            throw XcdError(.usage, "--idle \(text) is not a duration", next: "use a duration like 30s, 5m, or 1h, or off")
        }
        return seconds
    }

    /// 0 is "off"; a whole number of hours is "1h"; of minutes "10m", "90m"; anything else "45s".
    public static func text(_ seconds: Int) -> String {
        if seconds == 0 { return "off" }
        if seconds % 3600 == 0 { return "\(seconds / 3600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
}
