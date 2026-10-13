import Foundation

/// Where two versions of a text differ, line by line: what `xcd format` lists for a file it changed. A line is its text
/// with its line ending, so a newline added at the end of a file changes its last
/// line, and a line whose ending went from CRLF to LF is a changed line. It reads two texts and runs nothing.
struct LineDiff: Sendable, Equatable {
    /// One place where the texts differ: `oldCount` lines of the old text became `newCount` lines of the new. The
    /// starts count from 0. Either count can be 0: lines were only put in there, or only taken out.
    struct Hunk: Sendable, Equatable {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
    }

    let hunks: [Hunk]
    /// How many lines each text has.
    let oldCount: Int
    let newCount: Int

    init(from old: String, to new: String) {
        let before = Self.lines(of: old), after = Self.lines(of: new)
        let shorter = min(before.count, after.count)
        var same = 0, sameAtEnd = 0
        while same < shorter, before[same] == after[same] { same += 1 }
        while sameAtEnd < shorter - same, before[before.count - 1 - sameAtEnd] == after[after.count - 1 - sameAtEnd] { sameAtEnd += 1 }
        let script = EditScript(old: Array(before[same..<before.count - sameAtEnd]), new: Array(after[same..<after.count - sameAtEnd]))
        hunks = Self.hunks(script.unpaired(), after: same)
        oldCount = before.count
        newCount = after.count
    }

    /// The lines to list for the new text, numbered from 1: each run of lines the old text does not have. Where lines
    /// were only taken out, it is the line that now stands at that place.
    var newLines: [LineRange] { Self.listed(hunks.map { ($0.newStart, $0.newCount) }, of: newCount) }

    /// The lines to list for the old text: each run of lines the new text does not have. Where lines would only be
    /// put in, it is the line they would go before.
    var oldLines: [LineRange] { Self.listed(hunks.map { ($0.oldStart, $0.oldCount) }, of: oldCount) }

    /// A text's lines, each with the LF that ends it. Text after the last LF is a line too. The bytes are compared,
    /// not the characters, since Swift takes CRLF for one character and two spellings of an accented letter for equal.
    static func lines(of text: String) -> [ArraySlice<UInt8>] {
        let bytes = Array(text.utf8)
        var lines: [ArraySlice<UInt8>] = []
        var start = 0
        for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
            lines.append(bytes[start...index])
            start = index + 1
        }
        if start < bytes.count { lines.append(bytes[start...]) }
        return lines
    }

    /// The runs of lines without a partner, as hunks. Lines with a partner pair up in order, one of each text.
    /// `same` is how many lines the two texts share before the stretch the marks are for.
    static func hunks(_ unpaired: (old: [Bool], new: [Bool]), after same: Int) -> [Hunk] {
        var hunks: [Hunk] = []
        var old = 0, new = 0
        while old < unpaired.old.count || new < unpaired.new.count {
            let start = (old: old, new: new)
            while old < unpaired.old.count, unpaired.old[old] { old += 1 }
            while new < unpaired.new.count, unpaired.new[new] { new += 1 }
            if old > start.old || new > start.new {
                hunks.append(Hunk(oldStart: same + start.old, oldCount: old - start.old, newStart: same + start.new, newCount: new - start.new))
            } else {
                old += 1
                new += 1
            }
        }
        return hunks
    }

    /// Runs of lines, each a start counted from 0 and a count, as ranges numbered from 1 in a text of `total` lines.
    /// A run of no lines is the line at that place, or the last line when the place is the end of the text. Runs that
    /// touch are one range. A text with no lines has nothing to list.
    static func listed(_ runs: [(start: Int, count: Int)], of total: Int) -> [LineRange] {
        var ranges: [LineRange] = []
        for run in runs where total > 0 {
            let first = min(run.start + 1, total)
            let last = max(first, run.start + run.count)
            if let previous = ranges.last, first <= previous.last + 1 {
                ranges[ranges.count - 1] = LineRange(previous.first, max(previous.last, last))
            } else {
                ranges.append(LineRange(first, last))
            }
        }
        return ranges
    }
}

/// The shortest way to turn one list of lines into another by taking lines out and putting lines in (Myers'
/// algorithm), read as which lines of each list have no partner in the other.
struct EditScript {
    /// The longest script looked for. The work and the memory grow with the square of it, and two texts that far
    /// apart differ nearly everywhere, so beyond it every line counts as changed.
    static let mostEdits = 500

    let old: [ArraySlice<UInt8>]
    let new: [ArraySlice<UInt8>]

    var limit: Int { min(old.count + new.count, Self.mostEdits) }
    /// Where diagonal 0 is in a round's list. A diagonal is a number of old lines used less the new lines used.
    var middle: Int { limit + 1 }

    /// Whether the furthest path that ends on `diagonal` after `edits` edits got there by putting a new line in (from
    /// the diagonal above), and not by taking an old line out (from the one below).
    func putsIn(_ reach: [Int], _ diagonal: Int, _ edits: Int) -> Bool {
        diagonal == -edits || (diagonal != edits && reach[middle + diagonal - 1] < reach[middle + diagonal + 1])
    }

    /// For 0, 1, 2… edits: how many old lines the furthest path on each diagonal has used, as it stood before that
    /// round. The last round is the one that used up both lists. Nil when `limit` edits are not enough.
    func rounds() -> [[Int]]? {
        var reach = [Int](repeating: 0, count: 2 * limit + 3)
        var rounds: [[Int]] = []
        for edits in 0...limit {
            rounds.append(reach)
            for diagonal in stride(from: -edits, through: edits, by: 2) {
                var used = putsIn(reach, diagonal, edits) ? reach[middle + diagonal + 1] : reach[middle + diagonal - 1] + 1
                while used < old.count, used - diagonal < new.count, old[used] == new[used - diagonal] { used += 1 }
                reach[middle + diagonal] = used
                if used >= old.count, used - diagonal >= new.count { return rounds }
            }
        }
        return nil
    }

    /// Which lines have no partner, found by walking the last round's path back to the start: each round ends with
    /// one edit, then lines that pair up.
    func unpaired() -> (old: [Bool], new: [Bool]) {
        guard let rounds = rounds() else { return (old.map { _ in true }, new.map { _ in true }) }
        var marks = (old: [Bool](repeating: false, count: old.count), new: [Bool](repeating: false, count: new.count))
        var diagonal = old.count - new.count
        for edits in stride(from: rounds.count - 1, to: 0, by: -1) {
            let putIn = putsIn(rounds[edits], diagonal, edits)
            diagonal += putIn ? 1 : -1
            let used = rounds[edits][middle + diagonal]
            if putIn { marks.new[used - diagonal] = true } else { marks.old[used] = true }
        }
        return marks
    }
}
