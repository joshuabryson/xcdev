import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The lines a change touched. Git is real.
@Suite struct ChangedLinesTests {
    static let ten = (1...10).map { "let l\($0) = \($0)\n" }.joined()

    /// `main` holds `files`, each with the ten lines of `ten`. Branch `work` is checked out.
    func project(_ files: [String] = ["A.swift"]) throws -> (project: TempProject, fork: String) {
        let project = try TempProject.make(config: "version: 1\nproject: App.xcodeproj\n")
        for file in files { try project.write(Self.ten, to: file) }
        let fork = try project.commit("Base")
        try project.git("checkout", "-q", "-b", "work")
        return (project, fork)
    }

    /// `ten` with each line in `edits` rewritten, the lines in `removed` taken out, and `added` put at the end.
    func text(editing edits: [Int] = [], removing removed: [Int] = [], adding added: Int = 0) -> String {
        let kept = (1...10).filter { !removed.contains($0) }.map { edits.contains($0) ? "let l\($0) = 0\n" : "let l\($0) = \($0)\n" }
        return kept.joined() + (0..<added).map { "let n\($0) = 0\n" }.joined()
    }

    func part(_ project: TempProject, _ fork: String, _ path: String = "A.swift", was basePath: String? = nil) async throws -> ChangedPart {
        let file = ScopedFile(path: path, basePath: basePath ?? path)
        return try await ChangedLines(runner: SystemProcessRunner()).part(of: file, in: project.root, since: fork)
    }

    @Test func aHunkHeaderHasThreeForms() throws {
        #expect(ChangedLines.range(ofHunk: "@@ -2 +2 @@") == LineRange(2, 2))
        #expect(ChangedLines.range(ofHunk: "@@ -6,0 +6,2 @@ func body() {") == LineRange(6, 7))
        #expect(ChangedLines.range(ofHunk: "@@ -4 +3,0 @@") == nil)
        #expect(ChangedLines.range(ofHunk: "+@@ -1 +1 @@") == nil && ChangedLines.range(ofHunk: "@@ nonsense") == nil)
        #expect(ChangedLines.parse("diff --git a/A.swift b/A.swift\n@@ -2 +2 @@\n-a\n+b\n@@ -4 +3,0 @@\n-c\n@@ -9,0 +9,3 @@ x\n+d\n+e\n+f\n")
                == .lines([LineRange(2, 2), LineRange(9, 11)]))
        #expect(LineRange(40, 47).text == "40-47" && LineRange(120, 120).text == "120")
        #expect(String(decoding: try JSONEncoder().encode([LineRange(40, 47)]), as: UTF8.self) == "[[40,47]]")
    }

    @Test func editedAndAddedLinesAreRangesAndRemovedLinesAreNone() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        try project.write(text(editing: [2, 4], adding: 2), to: "A.swift")
        #expect(try await part(project, fork) == .lines([LineRange(2, 2), LineRange(4, 4), LineRange(11, 12)]))
        try project.write(text(removing: [5, 6]), to: "A.swift")
        #expect(try await part(project, fork) == .lines([]))
        try project.write(Self.ten, to: "A.swift")
        #expect(try await part(project, fork) == .lines([]))
    }

    /// The change is everything since the fork point, whatever state git holds it in.
    @Test func committedStagedAndUnstagedEditsAllCount() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        try project.write(text(editing: [2]), to: "A.swift")
        try project.commit("Edit line 2")
        try project.write(text(editing: [2, 5]), to: "A.swift")
        try project.git("add", "A.swift")
        try project.write(text(editing: [2, 5, 9]), to: "A.swift")
        #expect(try await part(project, fork) == .lines([LineRange(2, 2), LineRange(5, 5), LineRange(9, 9)]))
    }

    @Test func aRenamedFileIsMeasuredAgainstItsOldPath() async throws {
        let (project, fork) = try project(["Old.swift", "Kept.swift"])
        defer { project.remove() }
        try project.git("mv", "Old.swift", "New.swift")
        #expect(try await part(project, fork, "New.swift", was: "Old.swift") == .lines([]))          // only renamed
        try project.write(text(editing: [9]), to: "New.swift")
        #expect(try await part(project, fork, "New.swift", was: "Old.swift") == .lines([LineRange(9, 9)]))
    }

    @Test func aFileTheForkPointLacksIsWhole() async throws {
        let (project, fork) = try project(["A.swift", "Dropped.swift"])
        defer { project.remove() }
        try project.write(Self.ten, to: "Fresh.swift")
        let fresh = try await ChangedLines(runner: SystemProcessRunner()).part(of: ScopedFile(path: "Fresh.swift", basePath: nil), in: project.root, since: fork)
        #expect(fresh == .whole)
        // A path that was a link at the fork point and is a file now.
        try FileManager.default.createSymbolicLink(atPath: project.root + "/Link.swift", withDestinationPath: "A.swift")
        let linked = try project.commit("A link")
        try FileManager.default.removeItem(atPath: project.root + "/Link.swift")
        try project.write(Self.ten, to: "Link.swift")
        #expect(try await part(project, linked, "Link.swift") == .whole)
        // A file git was told to forget and that is still on disk.
        try project.git("rm", "-q", "--cached", "Dropped.swift")
        #expect(try await part(project, fork, "Dropped.swift") == .whole)
    }

    @Test func aNameWithASpaceBracketsOrAnAccentIsOneFile() async throws {
        let names = ["My File.swift", "List[1].swift", "Naïve*.swift"]
        let (project, fork) = try project(names + ["List1.swift"])
        defer { project.remove() }
        for (index, name) in names.enumerated() { try project.write(text(editing: [index + 3]), to: name) }
        try project.write(text(editing: [8]), to: "List1.swift")                        // what `List[1].swift` matches as a pattern
        for (index, name) in names.enumerated() {
            #expect(try await part(project, fork, name) == .lines([LineRange(index + 3, index + 3)]), "\(name)")
        }
    }

    /// A person's git settings can join nearby changes into one hunk, colour the output, or hand the diff to another
    /// program. None of that may reach xcd: joined hunks would have the formatter touch lines the change did not.
    @Test func thePersonsGitSettingsDoNotChangeTheRanges() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        try project.write(text(editing: [2, 4]), to: "A.swift")
        for setting in [["diff.interHunkContext", "3"], ["color.ui", "always"], ["color.diff", "always"], ["diff.external", "echo"],
                        ["diff.noprefix", "true"], ["diff.context", "5"], ["diff.renames", "false"], ["diff.counted.textconv", "wc -c"]] {
            try project.git("config", setting[0], setting[1])
        }
        try project.write("*.swift diff=counted\n", to: ".gitattributes")       // Swift files are compared as their byte counts
        #expect(try await part(project, fork) == .lines([LineRange(2, 2), LineRange(4, 4)]))
        try project.git("mv", "A.swift", "B.swift")
        #expect(try await part(project, fork, "B.swift", was: "A.swift") == .lines([LineRange(2, 2), LineRange(4, 4)]))
    }

    @Test func aFileInAnUnresolvedConflictHasItsMarkersAmongItsChangedLines() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        try project.write(text(editing: [7]), to: "A.swift")
        try project.commit("Work edits line 7")
        try project.git("checkout", "-q", "main")
        try project.write(Self.ten.replacingOccurrences(of: "let l7 = 7", with: "let l7 = 70"), to: "A.swift")
        try project.commit("Main edits line 7")
        try project.git("checkout", "-q", "work")
        #expect(throws: XcdError.self) { try project.git("merge", "main") }
        let part = try await part(project, fork)
        guard case .lines(let ranges) = part else { Issue.record("a conflicted file is still measured line by line"); return }
        let lines = try String(contentsOfFile: project.root + "/A.swift", encoding: .utf8).split(separator: "\n")
        let touched = ranges.flatMap { Array($0.first...$0.last) }.map { String(lines[$0 - 1]) }
        #expect(touched.contains { $0.hasPrefix("<<<<<<<") } && touched.contains { $0.hasPrefix(">>>>>>>") })
    }

    @Test func aForkPointGitDoesNotKnowIsAFailureNotAnEmptyAnswer() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        let error = await #expect(throws: XcdError.self) { _ = try await part(project, "0000000000000000000000000000000000000001") }
        #expect(error?.code == .subprocessFailed)
    }
}
