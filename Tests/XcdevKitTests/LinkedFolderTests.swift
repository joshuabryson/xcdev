import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Whether the temporary folder's volume takes `foo` and `Foo` for one name, as a Mac's volumes do unless they
/// were set up otherwise.
private let namesIgnoreCase: Bool = {
    let volume = try? URL(fileURLWithPath: NSTemporaryDirectory()).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    return volume?.volumeSupportsCaseSensitiveNames == false
}()

/// A tracked folder that the working tree replaced by a link to a folder elsewhere. To git its files were deleted,
/// while their paths lead through the link to files that are not the
/// worktree's: no scope holds them, and `xcd format` writes none of them. Git is real; the formatters are
/// `FakeFormatters`.
@Suite struct LinkedFolderTests {
    /// What the file outside the repository holds: blanks at a line's end and a tab, which a formatter would change.
    static let outside = "let l = 1   \n\tlet m = 2\n"

    let finder = ChangeFinder(runner: SystemProcessRunner())

    /// `main` gains `Lib/L.swift`. Then `Lib` becomes a link to a folder beside the repository that has an `L.swift`
    /// of its own, whose path is returned.
    func replaceLibByALink(in project: TempProject) throws -> String {
        try project.write("let l = 1\n", to: "Lib/L.swift")
        try project.commit("A folder")
        try project.git("branch", "-f", "main", "HEAD")
        try FileManager.default.removeItem(atPath: project.root + "/Lib")
        try project.write(Self.outside, to: "Elsewhere/L.swift", in: project.base)
        try FileManager.default.createSymbolicLink(atPath: project.root + "/Lib", withDestinationPath: project.base + "/Elsewhere")
        return project.base + "/Elsewhere/L.swift"
    }

    @Test func noScopeHoldsAFileUnderAFolderThatBecameALink() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        _ = try replaceLibByALink(in: project.project)
        let main = try project.project.rev("main")
        // What git says, and where the path leads: this is the trap.
        #expect(try await finder.records(["diff", "--name-status", "-z", main], in: project.root) == ["D", "Lib/L.swift"])
        #expect(try await finder.records(["ls-files", "--cached", "-z", "Lib"], in: project.root) == ["Lib/L.swift"])
        #expect(try project.read("Lib/L.swift") == Self.outside)

        #expect(try await finder.changed(in: project.root, since: main).isEmpty)
        #expect(try await finder.everyFile(in: project.root).map(\.path) == ["Sources/App/A.swift", "Sources/App/B.swift"])
    }

    /// In the default scope and with `--all`: the file is not listed, no formatter is handed it, and the file
    /// outside has every byte it had. The worktree's own files are still formatted.
    @Test(arguments: [false, true])
    func formatLeavesAFileOutsideTheWorktreeAsItWas(all: Bool) async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        let outside = try replaceLibByALink(in: project.project)
        try project.change()
        let ctx = try await project.context()
        let formatters = FakeFormatters()
        let report = try await project.service(formatters).format(FormatOptions(all: all), in: ctx)

        #expect(try Data(contentsOf: URL(fileURLWithPath: outside)) == Data(Self.outside.utf8))
        #expect(report.changed.map(\.file) == ["Sources/App/A.swift", "Sources/App/C.swift"] && report.failed.isEmpty)
        #expect(report.files == (all ? 3 : 2) && report.failure == nil)
        #expect(!formatters.runs.contains { $0.file.hasSuffix("/L.swift") })
    }

    /// As before: a tracked file that became a link itself is in no scope either.
    @Test func aTrackedFileThatBecameALinkIsStillInNoScope() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        let outside = project.project.base + "/Elsewhere/B.swift"
        try project.project.write(Self.outside, to: "Elsewhere/B.swift", in: project.project.base)
        try FileManager.default.removeItem(atPath: project.root + "/Sources/App/B.swift")
        try FileManager.default.createSymbolicLink(atPath: project.root + "/Sources/App/B.swift", withDestinationPath: outside)
        #expect(try await finder.changed(in: project.root, since: project.fork).isEmpty)
        #expect(try await finder.everyFile(in: project.root).map(\.path) == ["Sources/App/A.swift"])
        let ctx = try await project.context()
        let report = try await project.service(FakeFormatters()).format(FormatOptions(all: true), in: ctx)
        #expect(report.files == 1 && report.failed.isEmpty)
        #expect(try Data(contentsOf: URL(fileURLWithPath: outside)) == Data(Self.outside.utf8))
    }

    /// A file renamed on disk in its case only keeps the name git knows it by, and a path with links resolved spells
    /// each name as the disk has it. Such a file passes through no link, so it stays in scope: the folders on the way
    /// are looked at one by one, and no spelling is compared.
    @Test(.enabled(if: namesIgnoreCase, "needs a volume that ignores case in names"))
    func aFileWhoseNameDiffersFromGitsOnlyInCaseStaysInScope() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        let folder = project.root + "/Sources/App"
        try FileManager.default.moveItem(atPath: folder + "/B.swift", toPath: folder + "/b-moving.swift")
        try FileManager.default.moveItem(atPath: folder + "/b-moving.swift", toPath: folder + "/b.swift")
        try project.project.write("func b() {}   \n", to: "Sources/App/b.swift")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).sorted() == ["A.swift", "b.swift"])
        #expect(try await finder.changed(in: project.root, since: project.fork)
                == [ScopedFile(path: "Sources/App/B.swift", basePath: "Sources/App/B.swift")])
        #expect(try await finder.everyFile(in: project.root).map(\.path) == ["Sources/App/A.swift", "Sources/App/B.swift"])
    }
}
