/// The first line of what `xcd lint` and `xcd format` print:
/// `lint: 2 new findings  tool=swiftlint  files=3  base=main  1.8s`.
struct QualityHeadline {
    /// What `tool` says when the section's tool is `none`.
    static let noTool = "none"

    /// The command and its config section: `lint` or `format`.
    let command: String
    let tool: String
    let files: Int
    let base: String?
    let seconds: Double

    /// The line for `summary`, the words after the command's name. With no tool, or with no file in scope, the line
    /// says only what was not done and why.
    func text(_ summary: String) -> String {
        var parts = ["\(command): " + summary]
        guard tool != Self.noTool else { return parts[0] + "  (\(command).tool is none)" }
        parts.append("tool=\(tool)")
        guard files > 0 else { return parts.joined(separator: "  ") }
        parts.append("files=\(files)")
        if let base { parts.append("base=\(base)") }
        parts.append(DurationText.format(.seconds(seconds)))
        return parts.joined(separator: "  ")
    }

    /// `1 file`, `2 files`.
    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}
