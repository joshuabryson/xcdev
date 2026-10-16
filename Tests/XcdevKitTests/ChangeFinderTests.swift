import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Which Swift files a quality command covers. Real git, throwaway repos.
@Suite struct ChangeFinderTests {
    let finder = ChangeFinder(runner: SystemProcessRunner())

    /// `main` holds three Swift files, a text file, and an ignore rule for `Generated/`. Branch `work` is checked out.
    func project() throws -> (project: TempProject, fork: String) {
        let project = try TempProject.make(config: "version: 1\nproject: App.xcodeproj\n")
        try project.write("let a = 1\n", to: "Sources/App/A.swift")
        try project.write("let b = 1\n", to: "Sources/App/B.swift")
        try project.write("let old = 1\nlet kept = 2\nlet alsoKept = 3\n", to: "Sources/App/Old Name.swift")
        try project.write("notes\n", to: "Docs/notes.txt")
        try project.write("Generated/\n", to: ".gitignore")
        let fork = try project.commit("Base")
        try project.git("checkout", "-q", "-b", "work")
        return (project, fork)
    }

    func files(_ project: TempProject, since fork: String) async throws -> [ScopedFile] {
        try await finder.changed(in: project.root, since: fork)
    }

    @Test func committedStagedUnstagedAndUntrackedWorkAllCount() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        try project.write("let a = 2\n", to: "Sources/App/A.swift")
        try project.commit("Committed")
        try project.write("let b = 2\n", to: "Sources/App/B.swift")
        try project.git("add", "Sources/App/B.swift")
        try project.write("let c = 1\n", to: "Sources/App/C.swift")
        try project.git("add", "Sources/App/C.swift")
        try project.write("let d = 1\n", to: "Sources/App/D.swift")                    // untracked
        try project.write("let b = 3\n", to: "Sources/App/B.swift")                    // and edited again, unstaged

        #expect(try await files(project, since: fork) == [
            ScopedFile(path: "Sources/App/A.swift", basePath: "Sources/App/A.swift"),
            ScopedFile(path: "Sources/App/B.swift", basePath: "Sources/App/B.swift"),
            ScopedFile(path: "Sources/App/C.swift", basePath: nil),
            ScopedFile(path: "Sources/App/D.swift", basePath: nil),
        ])
    }

    @Test func deletedIgnoredAndOtherKindsOfFilesAreLeftOut() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        try FileManager.default.removeItem(atPath: project.root + "/Sources/App/A.swift")
        try project.write("more notes\n", to: "Docs/notes.txt")
        try project.write("let g = 1\n", to: "Generated/G.swift")                      // ignored
        try project.write("let s = 1\n", to: "Tools/build.swiftinterface")            // not .swift
        try project.commit("Change")
        #expect(try await files(project, since: fork).isEmpty)
    }

    /// The files whose warnings a build result lists are of every kind: a header's warning is in the files you changed.
    @Test func theFilesAChangeTouchedAreOfEveryKind() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        try project.write("more notes\n", to: "Docs/notes.txt")
        try project.write("int f(void);\n", to: "Sources/Obj/include/Obj.h")
        try project.write("let a = 2\n", to: "Sources/App/A.swift")
        try project.write("generated\n", to: "Generated/G.swift")
        try FileManager.default.removeItem(atPath: project.root + "/Sources/App/B.swift")
        #expect(try await finder.touched(in: project.root, since: fork) == ["Docs/notes.txt", "Sources/App/A.swift", "Sources/Obj/include/Obj.h"])
    }

    @Test func aRenamedFileCountsUnderItsNewPathAndRemembersItsOldOne() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        try project.git("mv", "Sources/App/Old Name.swift", "Sources/App/Néw Name.swift")
        try project.write("let new = 1\nlet kept = 2\nlet alsoKept = 3\n", to: "Sources/App/Néw Name.swift")
        try project.commit("Rename")
        #expect(try await files(project, since: fork) == [
            ScopedFile(path: "Sources/App/Néw Name.swift", basePath: "Sources/App/Old Name.swift"),
        ])
    }

    @Test func aSwiftFileThatIsALinkIsNotInScope() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        try FileManager.default.createSymbolicLink(atPath: project.root + "/Sources/App/Linked.swift",
                                                   withDestinationPath: project.root + "/Sources/App/A.swift")
        try FileManager.default.createDirectory(atPath: project.root + "/Sources/Folder.swift", withIntermediateDirectories: true)
        try project.write("x\n", to: "Sources/Folder.swift/readme.txt")
        #expect(try await files(project, since: fork).isEmpty)
        #expect(try await finder.everyFile(in: project.root).map(\.path)
                == ["Sources/App/A.swift", "Sources/App/B.swift", "Sources/App/Old Name.swift"])
    }

    @Test func aFileInAnUnresolvedConflictCountsAsModified() async throws {
        let (project, fork) = try project()
        defer { project.remove() }
        try project.write("let a = \"work\"\n", to: "Sources/App/A.swift")
        try project.commit("Work")
        try project.git("checkout", "-q", "main")
        try project.write("let a = \"main\"\n", to: "Sources/App/A.swift")
        try project.commit("Main")
        try project.git("checkout", "-q", "work")
        #expect(throws: XcdError.self) { try project.git("merge", "main") }           // stops on the conflict
        #expect(try await files(project, since: fork) == [ScopedFile(path: "Sources/App/A.swift", basePath: "Sources/App/A.swift")])
    }

    /// `--all`: tracked files and untracked ones that are not ignored. A tracked file deleted from disk is left out.
    @Test func theWholeProjectIsEverySwiftFileGitKnows() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        try project.write("let d = 1\n", to: "Sources/App/D.swift")
        try project.write("let g = 1\n", to: "Generated/G.swift")
        try project.write("*\n", to: ".xcdev/.gitignore")                             // as xcd writes it: the folder ignores itself
        try project.write("let x = 1\n", to: ".xcdev/SourcePackages/checkouts/Dep/X.swift")
        try FileManager.default.removeItem(atPath: project.root + "/Sources/App/B.swift")
        let files = try await finder.everyFile(in: project.root)
        #expect(files.map(\.path) == ["Sources/App/A.swift", "Sources/App/D.swift", "Sources/App/Old Name.swift"])
        #expect(files.allSatisfy { $0.basePath == nil })
    }
}

@Suite struct ScopePathsTests {
    /// A real folder tree, so that paths can be checked to exist: `<root>/Sources/App/A.swift` and `<root>/Tests`.
    func tree() throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-scope-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/Sources/App", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/Tests", withIntermediateDirectories: true)
        try "let a = 1\n".write(toFile: root + "/Sources/App/A.swift", atomically: true, encoding: .utf8)
        return Paths.canonical(root)
    }

    static let files = ["Sources/App/A.swift", "Sources/App/Views/V.swift", "Sources/AppKit/K.swift", "Tests/T.swift"]
        .map { ScopedFile(path: $0, basePath: nil) }

    @Test func aPathKeepsTheFileItNamesAndTheFilesUnderAFolder() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let scope = try ScopePaths(["Sources/App", "Tests/"], from: root, in: root)
        #expect(scope.prefixes == ["Sources/App", "Tests"])
        #expect(scope.narrow(Self.files).map(\.path) == ["Sources/App/A.swift", "Sources/App/Views/V.swift", "Tests/T.swift"])
        #expect(try ScopePaths(["Sources/App/A.swift"], from: root, in: root).narrow(Self.files).map(\.path) == ["Sources/App/A.swift"])
    }

    @Test func noPathsAndTheRootItselfKeepEverything() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(try ScopePaths([], from: root, in: root).narrow(Self.files) == Self.files)
        #expect(try ScopePaths(["."], from: root, in: root).narrow(Self.files) == Self.files)
        #expect(try ScopePaths([], from: root, in: root).isEmpty)
        #expect(try !ScopePaths(["."], from: root, in: root).isEmpty)
    }

    @Test func aPathIsReadFromTheCurrentDirectory() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(try ScopePaths(["App", "../Tests"], from: root + "/Sources", in: root).prefixes == ["Sources/App", "Tests"])
        #expect(try ScopePaths([root + "/Tests"], from: root + "/Sources", in: root).prefixes == ["Tests"])
    }

    /// With `--worktree` the current directory can be anywhere: then a path is read from the worktree root.
    @Test func fromOutsideTheWorktreeAPathIsReadFromItsRoot() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(try ScopePaths(["Sources/App"], from: "/usr/bin", in: root).prefixes == ["Sources/App"])
    }

    @Test func aPathOutsideTheWorktreeOrThatDoesNotExistIsAUsageError() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let outside = #expect(throws: XcdError.self) { try ScopePaths(["../elsewhere"], from: root, in: root) }
        #expect(outside?.code == .usage && outside?.message == "'../elsewhere' is outside this worktree")
        let missing = #expect(throws: XcdError.self) { try ScopePaths(["Sources/Gone.swift"], from: root, in: root) }
        #expect(missing?.code == .usage && missing?.message == "'Sources/Gone.swift' does not exist")
        #expect(missing?.next == "name files or folders inside \(root)")
    }
}
