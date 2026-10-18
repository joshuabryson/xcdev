import Foundation

/// xcd's block in a project's AGENTS.md or CLAUDE.md, between its two marker lines.
/// Everything outside the markers is the project's and is never changed.
enum AgentBlock {
    static let begin = "<!-- xcd:begin"
    static let end = "<!-- xcd:end -->"

    /// Where the block is in a file's text.
    enum Found: Equatable {
        case none
        /// From the start of the begin marker's line through the end marker.
        case block(Range<String.Index>)
        /// A begin marker with no end marker after it.
        case unclosed
    }

    /// The block as this xcd writes it, its marker lines included, without a newline at its end.
    static var text: String { agentSnippet }

    static func find(in file: String) -> Found {
        var from = file.startIndex
        while let marker = file.range(of: begin, range: from..<file.endIndex) {
            if startsLine(file, marker.lowerBound) {
                guard let close = endMarker(in: file, from: marker.upperBound) else { return .unclosed }
                return .block(marker.lowerBound..<close.upperBound)
            }
            from = marker.upperBound
        }
        return .none
    }

    /// Whether a marker at `index` starts a line. `isNewline`, since Swift takes "\r\n" for one character.
    private static func startsLine(_ file: String, _ index: String.Index) -> Bool {
        index == file.startIndex || file[file.index(before: index)].isNewline
    }

    /// The first end marker after `from` that starts a line; one inside a line's text is not the block's end.
    private static func endMarker(in file: String, from: String.Index) -> Range<String.Index>? {
        var search = from
        while let close = file.range(of: end, range: search..<file.endIndex) {
            if startsLine(file, close.lowerBound) { return close }
            search = close.upperBound
        }
        return nil
    }

    /// `file` with this xcd's block in place of the one there, or after it, following one blank line. The block's lines
    /// end as the file's first line break does (`\r\n`, `\n`, or `\r`). Nil when a begin marker has no end marker after it.
    static func written(into file: String) -> String? {
        let ending = file.first(where: { ["\r\n", "\n", "\r"].contains($0) }).map { String($0) } ?? "\n"
        let block = text.replacingOccurrences(of: "\n", with: ending)
        switch find(in: file) {
        case .block(let range):
            return file.replacingCharacters(in: range, with: block)
        case .unclosed:
            return nil
        case .none:
            guard !file.isEmpty else { return block + ending }
            let trailing = file.reversed().prefix(while: \.isNewline).count
            return file + String(repeating: ending, count: max(0, 2 - trailing)) + block + ending
        }
    }

    /// Whether the block in `file` is this xcd's, line endings aside (`\r\n` and a lone `\r` count as `\n`).
    static func isCurrent(in file: String) -> Bool {
        guard case .block(let range) = find(in: file) else { return false }
        let lines = file[range].replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return lines == text
    }

    /// Whether a line outside the block mentions xcd: one holding "`xcd " or "xcdev".
    static func mentionsXcdOutside(_ file: String) -> Bool {
        var outside = file
        if case .block(let range) = find(in: file) { outside.removeSubrange(range) }
        return outside.split(whereSeparator: \.isNewline).contains { $0.contains("`xcd ") || $0.contains("xcdev") }
    }

    /// Whether the Claude file at `claudeFile` (relative to the checkout) imports the checkout's AGENTS.md, on a line of
    /// its own, so that Claude Code reads the block through it. Claude Code resolves the import from the Claude file's
    /// folder: `@AGENTS.md` or `@./AGENTS.md` in `CLAUDE.md`, `@../AGENTS.md` in `.claude/CLAUDE.md`.
    static func importsAgentsFile(_ file: String, from claudeFile: String = "CLAUDE.md") -> Bool {
        let up = String(repeating: "../", count: max(0, claudeFile.split(separator: "/").count - 1))
        let imports = up.isEmpty ? ["@AGENTS.md", "@./AGENTS.md"] : ["@\(up)AGENTS.md"]
        return file.split(whereSeparator: \.isNewline).contains { imports.contains($0.trimmingCharacters(in: .whitespaces)) }
    }
}
