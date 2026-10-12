import Foundation

/// Tells the findings a change introduced from the ones a file already had. It runs no
/// process and reads no file.
public enum FindingComparison {
    /// What identifies a finding in two versions of a file: its rule, and the text of its line without the
    /// whitespace around it. Not the line's number, which moves, and not the message, which carries numbers.
    struct Key: Hashable, Sendable {
        let rule: String
        let text: String
    }

    /// The findings of `current` that have no partner in `base`, in line order. With no base version, all of them.
    public static func newFindings(in current: FileFindings, against base: FileFindings?) -> [LintFinding] {
        let ordered = inLineOrder(current.findings)
        guard let base else { return ordered }
        let fresh = unpaired(keys(ordered, in: current.text), from: keys(inLineOrder(base.findings), in: base.text))
        return fresh.map { ordered[$0] }
    }

    static func inLineOrder(_ findings: [LintFinding]) -> [LintFinding] {
        findings.sorted { ($0.line ?? 0, $0.column ?? 0, $0.rule) < ($1.line ?? 0, $1.column ?? 0, $1.rule) }
    }

    /// The key of each finding. A finding with no line, or with a line the text does not have, has no text.
    /// Lines end where a compiler ends them: at LF, CRLF, or CR. (In a Swift string CRLF is one character.)
    static func keys(_ findings: [LintFinding], in text: String) -> [Key] {
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
        return findings.map { finding in
            let line = finding.line.flatMap { lines.indices.contains($0 - 1) ? lines[$0 - 1] : nil }
            return Key(rule: finding.rule, text: (line ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The positions in `current` left without a partner in `base`. Entries are paired in two steps: first the
    /// longest sequence that both lists hold in the same order, then, among what is left on both sides, any two
    /// that are equal, which pairs findings in code that moved past other code.
    static func unpaired(_ current: [Key], from base: [Key]) -> [Int] {
        var leftInBase: [Key: Int] = [:]
        var leftInCurrent: [Int] = []
        for change in current.difference(from: base) {
            switch change {
            case .remove(_, let key, _): leftInBase[key, default: 0] += 1
            case .insert(let offset, _, _): leftInCurrent.append(offset)
            }
        }
        return leftInCurrent.sorted().filter { offset in
            guard let count = leftInBase[current[offset]], count > 0 else { return true }
            leftInBase[current[offset]] = count - 1
            return false
        }
    }
}
