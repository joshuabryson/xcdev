import Foundation
import Testing
@testable import XcdevKit

/// Which lines two versions of a text differ in.
@Suite struct LineDiffTests {
    /// Lines 1 to `count`, each `line <n>`, with `changes` applied: a replacement text per line number (nil takes the line out).
    func text(_ count: Int, _ changes: [Int: String?] = [:]) -> String {
        (1...count).compactMap { number -> String? in
            guard let change = changes[number] else { return "line \(number)\n" }
            return change
        }.joined()
    }

    func ranges(_ pairs: [(Int, Int)]) -> [LineRange] { pairs.map { LineRange($0.0, $0.1) } }

    @Test func textsThatAreTheSameDifferNowhere() {
        let diff = LineDiff(from: text(5), to: text(5))
        #expect(diff.hunks.isEmpty && diff.newLines.isEmpty && diff.oldLines.isEmpty)
        #expect(LineDiff(from: "", to: "").hunks.isEmpty)
    }

    @Test func editedLinesAreListedOnBothSides() {
        let diff = LineDiff(from: text(12), to: text(12, [3: "LINE 3\n", 4: "LINE 4\n", 9: "LINE 9\n"]))
        #expect(diff.newLines == ranges([(3, 4), (9, 9)]) && diff.oldLines == ranges([(3, 4), (9, 9)]))
        #expect(diff.hunks == [LineDiff.Hunk(oldStart: 2, oldCount: 2, newStart: 2, newCount: 2), LineDiff.Hunk(oldStart: 8, oldCount: 1, newStart: 8, newCount: 1)])
    }

    /// Where lines only went in, the old text has nothing that differs: it lists the line they went in before. The
    /// other way round, the new text lists the line that now stands where lines came out.
    @Test func linesPutInOrTakenOutAreAPlaceOnTheOtherSide() {
        let longer = text(6, [4: "new a\nnew b\nline 4\n"])
        let put = LineDiff(from: text(6), to: longer)
        #expect(put.newLines == ranges([(4, 5)]) && put.oldLines == ranges([(4, 4)]))
        let taken = LineDiff(from: longer, to: text(6))
        #expect(taken.newLines == ranges([(4, 4)]) && taken.oldLines == ranges([(4, 5)]))
        let atEnd = LineDiff(from: text(6), to: text(6, [5: nil, 6: nil]))
        #expect(atEnd.newLines == ranges([(4, 4)]) && atEnd.oldLines == ranges([(5, 6)]))        // the last line that is left
        let atStart = LineDiff(from: text(6), to: text(6, [1: nil]))
        #expect(atStart.newLines == ranges([(1, 1)]) && atStart.oldLines == ranges([(1, 1)]))
    }

    @Test func aTextWithNoLinesListsNothing() {
        let filled = LineDiff(from: "", to: text(3))
        #expect(filled.newLines == ranges([(1, 3)]) && filled.oldLines.isEmpty)
        let emptied = LineDiff(from: text(3), to: "")
        #expect(emptied.newLines.isEmpty && emptied.oldLines == ranges([(1, 3)]))
    }

    @Test func aNewlineAddedAtTheEndChangesTheLastLine() {
        let diff = LineDiff(from: "let a = 1\nlet b = 2", to: "let a = 1\nlet b = 2\n")
        #expect(diff.newLines == ranges([(2, 2)]) && diff.oldLines == ranges([(2, 2)]))
    }

    /// Swift takes CRLF for one character, and reads two spellings of an accented letter as equal. Bytes are compared.
    @Test func aLineEndingOrASpellingThatChangedIsAChangedLine() {
        let endings = LineDiff(from: "let a = 1\r\nlet b = 2\r\nlet c = 3\r\n", to: "let a = 1\r\nlet b = 2\nlet c = 3\r\n")
        #expect(endings.newLines == ranges([(2, 2)]) && endings.newCount == 3)
        let spelling = LineDiff(from: "// caf\u{E9}\n", to: "// cafe\u{301}\n")
        #expect(spelling.newLines == ranges([(1, 1)]))
    }

    @Test func placesThatTouchAreOneRange() {
        // Line 3 is taken out and line 4 is edited: two things at one place.
        let diff = LineDiff(from: text(6), to: text(6, [3: nil, 4: "LINE 4\n"]))
        #expect(diff.newLines == ranges([(3, 3)]) && diff.oldLines == ranges([(3, 4)]))
        #expect(LineDiff.listed([(start: 0, count: 2), (start: 2, count: 0), (start: 3, count: 1), (start: 9, count: 0)], of: 9)
                == ranges([(1, 4), (9, 9)]))
    }

    @Test func twoEditsFarApartInALongFileAreTwoLines() {
        let diff = LineDiff(from: text(20_000), to: text(20_000, [10: "LINE\n", 19_990: "LINE\n"]))
        #expect(diff.newLines == ranges([(10, 10), (19_990, 19_990)]))
    }

    /// Past `mostEdits` the stretch from the first difference to the last is one hunk: nearly all of it differs.
    @Test func textsThatDifferNearlyEverywhereAreOneRange() {
        let old = text(2_000)
        let new = "line 1\n" + (2...1_999).map { "  line \($0)\n" }.joined() + "line 2000\n"
        let diff = LineDiff(from: old, to: new)
        #expect(diff.hunks == [LineDiff.Hunk(oldStart: 1, oldCount: 1_998, newStart: 1, newCount: 1_998)])
        #expect(diff.newLines == ranges([(2, 1_999)]))
        #expect(EditScript.mostEdits == 500)
    }

    /// Every pair of texts of up to four lines over two different lines: the lines without a partner are as few as
    /// the standard library's own difference finds, and the others pair up, equal, in order.
    @Test func theScriptIsAShortestOneAndWhatItLeavesPairsUp() {
        let texts = (0...4).flatMap { length in (0..<(1 << length)).map { bits in (0..<length).map { bits >> $0 & 1 == 1 ? "a\n" : "b\n" } } }
        for old in texts {
            for new in texts {
                let script = EditScript(old: old.map { Array($0.utf8)[...] }, new: new.map { Array($0.utf8)[...] })
                let marks = script.unpaired()
                let shortest = new.difference(from: old)
                #expect(marks.old.filter { $0 }.count == shortest.removals.count && marks.new.filter { $0 }.count == shortest.insertions.count,
                        "\(old) to \(new)")
                let kept = (old: old.indices.filter { !marks.old[$0] }.map { old[$0] }, new: new.indices.filter { !marks.new[$0] }.map { new[$0] })
                #expect(kept.old == kept.new, "\(old) to \(new)")
            }
        }
    }
}
