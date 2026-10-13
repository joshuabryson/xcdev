import Foundation
import Testing
@testable import XcdevKit

/// The scratch folder SwiftLint runs in: copies of the files in scope and of the lint config.
@Suite struct LintFolderTests {
    /// A stand-in for a worktree: a folder with these files, each written as path and text. It sits in a folder of
    /// its own (`base`), so a test can put a file beside it.
    final class Worktree {
        let base: String
        let root: String

        init(_ files: [String: String]) throws {
            base = Paths.canonical(NSTemporaryDirectory()) + "/xcd-lintfolder-\(UUID().uuidString)"
            root = base + "/worktree"
            for (path, text) in files { try write(text, to: path) }
        }

        func write(_ text: String, to path: String) throws {
            let full = root + "/" + path
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: full, atomically: true, encoding: .utf8)
        }

        deinit { try? FileManager.default.removeItem(atPath: base) }
    }

    /// Every file and link in the folder, as relative paths in order. A link ends in ` -> `.
    func contents(of folder: LintFolder) throws -> [String] {
        let fm = FileManager.default
        return try fm.subpathsOfDirectory(atPath: folder.root).sorted().compactMap { path in
            let type = try fm.attributesOfItem(atPath: folder.root + "/" + path)[.type] as? FileAttributeType
            if type == .typeSymbolicLink { return path + " -> " }
            return type == .typeRegular ? path : nil
        }
    }

    func text(_ path: String, in folder: LintFolder) throws -> String {
        try String(contentsOfFile: folder.root + "/" + path, encoding: .utf8)
    }

    @Test func aNewFolderIsOutsideTheWorktreeAndRemoveDeletesIt() throws {
        let worktree = try Worktree(["A.swift": "let a = 1\n"])
        let folder = try LintFolder.create()
        #expect(!Paths.canonical(folder.root).hasPrefix(worktree.root))
        #expect(folder.root.contains("xcd-lint-"))
        try folder.write(Data("let a = 1\n".utf8), to: "Sources/App/A.swift")
        #expect(try text("Sources/App/A.swift", in: folder) == "let a = 1\n")
        folder.remove()
        #expect(!FileManager.default.fileExists(atPath: folder.root))
        folder.remove()                                                      // a second time is harmless
    }

    @Test func theConfigInTheRootAndOnTheWayToEachFileIsCopied() throws {
        let worktree = try Worktree([
            ".swiftlint.yml": "included: [Sources]\n",
            "Sources/App/.swiftlint.yml": "disabled_rules: [line_length]\n",
            "Sources/App/Views/V.swift": "let v = 1\n",
            "Sources/Other/.swiftlint.yml": "disabled_rules: [todo]\n",
            "Tests/.swiftlint.yml": "disabled_rules: [force_try]\n",
            "Sources/App/notes.txt": "not config\n",
        ])
        let folder = try LintFolder.create()
        defer { folder.remove() }
        try folder.write(Data("let v = 1\n".utf8), to: "Sources/App/Views/V.swift")
        try folder.copyConfig(from: worktree.root, for: ["Sources/App/Views/V.swift"], args: [])

        #expect(try contents(of: folder) == [".swiftlint.yml", "Sources/App/.swiftlint.yml", "Sources/App/Views/V.swift"])
        #expect(try text("Sources/App/.swiftlint.yml", in: folder) == "disabled_rules: [line_length]\n")
    }

    @Test func aConfigNamedInArgsIsCopiedWithTheFilesItNames() throws {
        let worktree = try Worktree([
            "ci/lint.yml": "parent_config: ../shared/base.yml\nchild_config: more.yml\n",
            "shared/base.yml": "parent_config: \"../ci/lint.yml\"\nline_length: 100\n",     // a loop must not hang
            "ci/more.yml": "child_config: ./deeper/last.yml\n",
            "ci/deeper/last.yml": "opt_in_rules: [empty_count]\n",
            "ci/second.yml": "disabled_rules: [todo]\n",
            "A.swift": "let a = 1\n",
        ])
        let folder = try LintFolder.create()
        defer { folder.remove() }
        try folder.copyConfig(from: worktree.root, for: ["A.swift"], args: ["--strict", "--config", "ci/lint.yml", "--config=ci/second.yml"])
        #expect(try contents(of: folder) == ["ci/deeper/last.yml", "ci/lint.yml", "ci/more.yml", "ci/second.yml", "shared/base.yml"])
    }

    @Test func aConfigOutsideTheWorktreeOrAtAURLIsNotCopied() throws {
        let name = "outside-\(UUID().uuidString).yml"
        let worktree = try Worktree([
            ".swiftlint.yml": "parent_config: https://example.com/base.yml\nchild_config: ../\(name)\n",
            "A.swift": "let a = 1\n",
        ])
        try "line_length: 90\n".write(toFile: worktree.base + "/" + name, atomically: true, encoding: .utf8)
        let folder = try LintFolder.create()
        defer { folder.remove() }
        let beside = (folder.root as NSString).deletingLastPathComponent + "/" + name
        defer { try? FileManager.default.removeItem(atPath: beside) }
        try folder.copyConfig(from: worktree.root, for: ["A.swift"], args: ["--config", "missing.yml", "--config", "../\(name)", "--config"])
        #expect(try contents(of: folder) == [".swiftlint.yml"])
        #expect(!FileManager.default.fileExists(atPath: beside))               // nothing was written beside the folder either
    }

    /// SwiftLint follows an absolute path out of the folder it runs in and lints the files beside it.
    @Test(arguments: [
        Refusal(files: [:], args: ["--config", "/etc/hosts"], subject: "lint.args: --config /etc/hosts"),
        Refusal(files: [:], args: ["--config=/etc/hosts"], subject: "lint.args: --config /etc/hosts"),
        Refusal(files: [".swiftlint.yml": "parent_config: /shared/base.yml\n"], args: [],
                subject: ".swiftlint.yml: parent_config: /shared/base.yml"),
        Refusal(files: ["Sources/App/.swiftlint.yml": "child_config: /shared/more.yml\n"], args: [],
                subject: "Sources/App/.swiftlint.yml: child_config: /shared/more.yml"),
        Refusal(files: [".swiftlint.yml": "included:\n  - Sources\n  - /elsewhere/Sources\n"], args: [],
                subject: ".swiftlint.yml: included: /elsewhere/Sources"),
    ])
    func aConfigWithAnAbsolutePathIsRefusedAndNothingIsWritten(_ refusal: Refusal) throws {
        let worktree = try Worktree(refusal.files.merging(["Sources/App/A.swift": "let a = 1\n"]) { first, _ in first })
        let folder = try LintFolder.create()
        defer { folder.remove() }
        let error = try #require(throws: XcdError.self) {
            try folder.copyConfig(from: worktree.root, for: ["Sources/App/A.swift"], args: refusal.args)
        }
        #expect(error.code == .configInvalid)
        #expect(error.message == refusal.subject + " is an absolute path, which xcd lint cannot follow")
        #expect(error.next?.contains("lint.run") == true)
        #expect(try contents(of: folder).isEmpty)
    }

    @Test func aConfigWhoseIncludedHoldsOnlyRelativeEntriesIsCopied() throws {
        let worktree = try Worktree([".swiftlint.yml": "included:\n  - Sources\n  - ./Tests\nexcluded: [/not/checked]\n"])
        let folder = try LintFolder.create()
        defer { folder.remove() }
        try folder.copyConfig(from: worktree.root, for: [], args: [])
        #expect(try contents(of: folder) == [".swiftlint.yml"])
    }

    struct Refusal: Sendable, CustomTestStringConvertible {
        let files: [String: String]
        let args: [String]
        let subject: String
        var testDescription: String { subject }
    }

    /// SwiftLint keeps its copy of a `parent_config` that is a URL here, and uses it when it cannot reach the URL.
    @Test func theRemoteConfigCacheIsCopied() throws {
        let worktree = try Worktree([
            ".swiftlint.yml": "parent_config: https://example.com/base.yml\n",
            ".swiftlint/RemoteConfigCache/v1/https___example.com_base.yml.yml": "line_length: 90\n",
            ".swiftlint/other/x.txt": "not the cache\n",
        ])
        let folder = try LintFolder.create()
        defer { folder.remove() }
        try folder.copyConfig(from: worktree.root, for: [], args: [])
        #expect(try contents(of: folder) == [".swiftlint.yml", ".swiftlint/RemoteConfigCache/v1/https___example.com_base.yml.yml"])
    }

    /// A config file that is a link is copied as the file it points to, so nothing in the folder leads out of it.
    @Test func nothingInTheFolderIsALink() throws {
        let worktree = try Worktree(["shared/lint.yml": "line_length: 100\n", "A.swift": "let a = 1\n"])
        try FileManager.default.createSymbolicLink(atPath: worktree.root + "/.swiftlint.yml", withDestinationPath: "shared/lint.yml")
        let folder = try LintFolder.create()
        defer { folder.remove() }
        try folder.copyConfig(from: worktree.root, for: ["A.swift"], args: [])
        #expect(try contents(of: folder) == [".swiftlint.yml"])
        #expect(try text(".swiftlint.yml", in: folder) == "line_length: 100\n")
    }

    /// SwiftLint reports this itself (it falls back to its defaults); the file is still handed to it.
    @Test func aConfigThatIsNotYAMLIsCopiedAndFollowedNoFurther() throws {
        let worktree = try Worktree([".swiftlint.yml": "included: [Sources\nparent_config: base.yml\n", "base.yml": "x: 1\n"])
        let folder = try LintFolder.create()
        defer { folder.remove() }
        try folder.copyConfig(from: worktree.root, for: ["Sources/A.swift"], args: [])
        #expect(try contents(of: folder) == [".swiftlint.yml"])
    }

    /// SwiftLint gives absolute paths, and drops a leading `/private` from them.
    @Test func aPathSwiftLintReportsMapsBackToThePathInTheFolder() throws {
        let folder = try LintFolder.create()
        defer { folder.remove() }
        try folder.write(Data("let a = 1\n".utf8), to: "Sources/My App/A.swift")
        let real = Paths.canonical(folder.root)
        #expect(folder.path(of: real + "/Sources/My App/A.swift") == "Sources/My App/A.swift")
        #expect(folder.path(of: "/private" + real + "/Sources/My App/A.swift") == "Sources/My App/A.swift")
        #expect(folder.path(of: folder.root + "/Sources/My App/A.swift") == "Sources/My App/A.swift")
        #expect(folder.path(of: "/somewhere/else/A.swift") == nil)
        #expect(folder.path(of: real) == nil)
    }
}
