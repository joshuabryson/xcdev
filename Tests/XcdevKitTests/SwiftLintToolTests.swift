import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Running SwiftLint in a scratch folder and reading what it gives. SwiftLint itself is a stub.
@Suite struct SwiftLintToolTests {
    let runner = FakeProcessRunner()

    func tool(args: [String] = []) -> SwiftLintTool {
        SwiftLintTool(runner: runner, executable: "/opt/homebrew/bin/swiftlint", args: args)
    }

    /// SwiftLint's JSON for findings, each written as the file's full path, line, column, severity, and rule.
    static func json(_ findings: [(String, Int?, Int?, String, String)]) -> String {
        let items = findings.map { file, line, column, severity, rule in
            """
              {
                "character" : \(column.map(String.init) ?? "null"),
                "file" : "\(file)",
                "line" : \(line.map(String.init) ?? "null"),
                "reason" : "Reason for \(rule)",
                "rule_id" : "\(rule)",
                "severity" : "\(severity)",
                "type" : "Type"
              }
            """
        }
        return "[\n" + items.joined(separator: ",\n") + "\n]\n"
    }

    func folder() throws -> LintFolder {
        let folder = try LintFolder.create()
        try folder.write(Data("let a = 1\n".utf8), to: "Sources/A.swift")
        return folder
    }

    @Test func swiftLintRunsInTheFolderWithNoPathsAndTheProjectsArguments() async throws {
        let folder = try folder()
        defer { folder.remove() }
        runner.stub(["swiftlint"], stdout: "[\n\n]\n")
        let run = try await tool(args: ["--strict", "--config", "ci/lint.yml"]).lint(folder)

        #expect(run.findings.isEmpty && run.notes.isEmpty)
        let call = try #require(runner.calls.first)
        #expect(call.executable == "/opt/homebrew/bin/swiftlint")
        #expect(call.arguments == ["lint", "--quiet", "--reporter", "json", "--no-cache", "--strict", "--config", "ci/lint.yml"])
        #expect(call.workingDirectory == folder.root)
        #expect(call.timeout == .seconds(600))
    }

    /// SwiftLint 0.63 exits 2 when a finding is an error. Other versions use other codes, so the code is not read.
    @Test func findingsAreReadFromTheListWhateverTheExitCode() async throws {
        let folder = try folder()
        defer { folder.remove() }
        let reported = Paths.canonical(folder.root)                             // as SwiftLint gives it: no /private
        for exitCode: Int32 in [0, 1, 2] {
            runner.stub(["swiftlint"], exitCode: exitCode, stdout: Self.json([
                (reported + "/Sources/A.swift", 2, 5, "Error", "identifier_name"),
                (reported + "/Sources/A.swift", 1, nil, "Warning", "file_name"),
                (reported + "/Sources/A.swift", nil, nil, "warning", "file_length"),
            ]))
            let run = try await tool().lint(folder)
            #expect(run.findings == [
                LintFinding(file: "Sources/A.swift", line: 2, column: 5, severity: .error, rule: "identifier_name", message: "Reason for identifier_name"),
                LintFinding(file: "Sources/A.swift", line: 1, column: nil, severity: .warning, rule: "file_name", message: "Reason for file_name"),
                LintFinding(file: "Sources/A.swift", line: nil, column: nil, severity: .warning, rule: "file_length", message: "Reason for file_length"),
            ])
        }
    }

    @Test func aConfigThatLeavesOutEveryFileGivesNoFindings() async throws {
        let folder = try folder()
        defer { folder.remove() }
        runner.stub(["swiftlint"], exitCode: 1, stderr: "Error: No lintable files found at paths: ''\n")
        let run = try await tool().lint(folder)
        #expect(run.findings.isEmpty)
        #expect(run.notes.isEmpty)                                              // it is the answer, not a note
    }

    /// A tool that broke is never reported as lint findings.
    @Test func anythingElseIsAToolThatFailed() async throws {
        let folder = try folder()
        defer { folder.remove() }
        for (exitCode, stdout, stderr) in [(Int32(1), "", "Fatal error: something broke\n"), (0, "Linting done\n", ""), (0, "", ""),
                                           (1, "", ""), (0, "", "Error: No lintable files found at paths: ''\n")] {
            runner.stub(["swiftlint"], exitCode: exitCode, stdout: stdout, stderr: stderr)
            let error = await #expect(throws: XcdError.self) { _ = try await tool().lint(folder) }
            #expect(error?.code == .subprocessFailed)
            #expect(error?.message == "swiftlint gave no result xcd can read (exit \(exitCode))")
            #expect(error?.details.first == "command: swiftlint lint --quiet --reporter json --no-cache")
            #expect(error?.next == "run `swiftlint lint` in the project to see what it says, and check lint.args in .xcdev.yml")
        }
    }

    @Test func whatSwiftLintWritesToStderrIsKeptAsNotes() async throws {
        let folder = try folder()
        defer { folder.remove() }
        runner.stub(["swiftlint"], stdout: "[\n\n]\n",
                    stderr: "warning: Cannot parse YAML file: bad – Falling back to default configuration\n\nwarning: second\n")
        let run = try await tool().lint(folder)
        #expect(run.notes == ["warning: Cannot parse YAML file: bad – Falling back to default configuration", "warning: second"])
        #expect(run.transcript.contains("$ swiftlint lint --quiet --reporter json --no-cache"))
        #expect(run.transcript.contains("warning: second") && run.transcript.contains("exit 0"))
    }

    /// A finding for a file outside the folder means SwiftLint did not lint what xcd gave it: that is no result.
    @Test func aFindingOutsideTheFolderIsARunThatLeftTheFolder() async throws {
        let folder = try folder()
        defer { folder.remove() }
        runner.stub(["swiftlint"], stdout: Self.json([("/somewhere/else/A.swift", 1, 1, "Warning", "todo"),
                                                      (folder.root + "/Sources/A.swift", 1, 1, "Warning", "todo")]))
        let error = await #expect(throws: XcdError.self) { _ = try await tool().lint(folder) }
        #expect(error?.code == .subprocessFailed)
        #expect(error?.message == "swiftlint linted a file outside the folder xcd gave it: /somewhere/else/A.swift")
        #expect(error?.next == "the lint config leads SwiftLint out of the copy xcd made: look for an absolute path or an environment variable in its included, parent_config, or child_config, and use a path relative to the worktree")
    }

    @Test func aRunThatTakesTooLongIsATimeout() async throws {
        let folder = try folder()
        defer { folder.remove() }
        runner.stub(["swiftlint"]) { _ in throw XcdError(.timeout, "`swiftlint lint` timed out after 10m") }
        let error = await #expect(throws: XcdError.self) { _ = try await tool().lint(folder) }
        #expect(error?.code == .timeout)
    }
}

@Suite struct ToolLocatorTests {
    /// A folder tree with an executable file at each of `paths`.
    func tree(_ paths: [String]) throws -> String {
        let root = Paths.canonical(NSTemporaryDirectory()) + "/xcd-locator-\(UUID().uuidString)"
        for path in paths {
            let full = root + "/" + path
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "#!/bin/sh\n".write(toFile: full, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: full)
        }
        return root
    }

    @Test func theConfiguredPathIsUsedAsItIsOrFromTheWorktreeRoot() throws {
        let root = try tree(["worktree/tools/swiftlint", "elsewhere/swiftlint", "bin/swiftlint"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let locator = ToolLocator(environment: ["PATH": root + "/bin"])
        #expect(locator.locate("swiftlint", path: "tools/swiftlint", worktreeRoot: root + "/worktree") == root + "/worktree/tools/swiftlint")
        #expect(locator.locate("swiftlint", path: root + "/elsewhere/swiftlint", worktreeRoot: root + "/worktree") == root + "/elsewhere/swiftlint")
        // A path that names nothing is not replaced by a search: the config said where the tool is.
        #expect(locator.locate("swiftlint", path: "tools/missing", worktreeRoot: root + "/worktree") == nil)
        #expect(locator.locate("swiftlint", path: "tools", worktreeRoot: root + "/worktree") == nil)       // a folder
    }

    @Test func withoutAPathTheFirstMatchInPathWinsThenTheUsualFolders() throws {
        let root = try tree(["first/other", "second/swiftlint", "third/swiftlint", "brew/swiftlint"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = [root + "/first", "", root + "/second", root + "/third"].joined(separator: ":")
        #expect(ToolLocator(environment: ["PATH": path]).locate("swiftlint", path: nil, worktreeRoot: root) == root + "/second/swiftlint")
        let fallback = ToolLocator(environment: ["PATH": root + "/first"], extraFolders: [root + "/missing", root + "/brew"])
        #expect(fallback.locate("swiftlint", path: nil, worktreeRoot: root) == root + "/brew/swiftlint")
        #expect(ToolLocator(environment: [:], extraFolders: []).locate("swiftlint", path: nil, worktreeRoot: root) == nil)
        #expect(ToolLocator(environment: [:]).folders == ["/opt/homebrew/bin", "/usr/local/bin"])
    }

    @Test func aFileThatCannotBeRunIsNotTheTool() throws {
        let root = try tree(["bin/swiftlint"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root + "/bin/swiftlint")
        #expect(ToolLocator(environment: ["PATH": root + "/bin"], extraFolders: []).locate("swiftlint", path: nil, worktreeRoot: root) == nil)
    }

    /// Homebrew's `swiftlint` is a link into its Cellar.
    @Test func aLinkToTheToolIsTheTool() throws {
        let root = try tree(["cellar/swiftlint"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/bin/swiftlint", withDestinationPath: root + "/cellar/swiftlint")
        #expect(ToolLocator(environment: ["PATH": root + "/bin"], extraFolders: []).locate("swiftlint", path: nil, worktreeRoot: root) == root + "/bin/swiftlint")
    }

    @Test func aMissingToolSaysHowToGetItOrWhereToPointAtIt() {
        let missing = ToolLocator.missing("swiftlint", section: "lint", path: nil)
        #expect(missing.code == .toolMissing && missing.code.exitCode == 3)
        #expect(missing.message == "swiftlint is not installed: it is not in PATH, /opt/homebrew/bin, or /usr/local/bin")
        #expect(missing.next == "brew install swiftlint, or set lint.path in .xcdev.local.yml")
        let wrongPath = ToolLocator.missing("swiftlint", section: "lint", path: "tools/swiftlint")
        #expect(wrongPath.message == "lint.path names 'tools/swiftlint', which is not a file that can be run")
        #expect(wrongPath.next == "fix lint.path in .xcdev.yml or .xcdev.local.yml, or remove it to have xcd look in PATH")
    }
}
