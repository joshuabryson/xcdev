import Foundation

/// Durations as agents type them: "500ms", "30s", "2m", "1.5h", or bare seconds ("45").
public enum DurationText {
    private static let units: [(suffix: String, seconds: Double)] = [("ms", 0.001), ("s", 1), ("m", 60), ("h", 3600)]
    private static let longest: Double = 7 * 24 * 3600

    public static func parse(_ text: String) -> Duration? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        var number = s
        var scale = 1.0
        if let unit = units.first(where: { s.hasSuffix($0.suffix) }) {
            number = String(s.dropLast(unit.suffix.count))
            scale = unit.seconds
        }
        guard let value = Double(number), value.isFinite else { return nil }
        let seconds = value * scale
        guard seconds > 0, seconds <= longest else { return nil }
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }

    public static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// "0.4s", "12.4s", "2m05s", "1h02m".
    public static func format(_ duration: Duration) -> String {
        let total = seconds(duration)
        if total < 59.95 { return String(format: "%.1fs", total) }
        let whole = Int(total.rounded())
        if whole < 3600 { return String(format: "%dm%02ds", whole / 60, whole % 60) }
        return String(format: "%dh%02dm", whole / 3600, (whole % 3600) / 60)
    }
}
