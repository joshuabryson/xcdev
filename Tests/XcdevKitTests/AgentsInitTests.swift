import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Which of AGENTS.md and CLAUDE.md get xcd's block, and `xcd init --agents`.
@Suite struct AgentsInitTests {
    static let block = AgentBlock.text + "\n"

    /// A folder holding `files` (path → text).
    func folder(_ files: [String: String]) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-agents-\(UUID().uuidString)").path
        for (path, text) in files {
            try FileManager.default.createDirectory(atPath: ((root + "/" + path) as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try text.write(toFile: root + "/" + path, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    func read(_ root: String, _ file: String) -> String? { try? String(contentsOfFile: root + "/" + file, encoding: .utf8) }

    @Test func aClaudeFileAloneGetsTheBlockAndNoAgentsFileIsMade() throws {
        let root = try folder(["CLAUDE.md": "# Ours\n"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let done = try AgentsInit(root: root).install(answer: nil)
        #expect(read(root, "CLAUDE.md") == "# Ours\n\n" + Self.block && read(root, "AGENTS.md") == nil)
        #expect(done == AgentsInstall(lines: ["CLAUDE.md: added xcd's block"], changed: ["CLAUDE.md"], warnings: []))
        #expect(AgentsInit(root: root).decision == nil)
    }

    @Test func aClaudeFileThatImportsTheAgentsFileIsLeftToTheImport() throws {
        let root = try folder(["AGENTS.md": "# Agents\n", "CLAUDE.md": "@AGENTS.md\n"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(try AgentsInit(root: root).install(answer: nil).changed == ["AGENTS.md"])
        #expect(read(root, "CLAUDE.md") == "@AGENTS.md\n")
    }

    @Test func bothFilesWithoutAnImportBothGetTheBlock() throws {
        let root = try folder(["AGENTS.md": "# Agents\n", "CLAUDE.md": "# Claude\n"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(try AgentsInit(root: root).install(answer: nil).changed == ["AGENTS.md", "CLAUDE.md"])
    }

    @Test func theClaudeFileCanBeInTheClaudeFolder() throws {
        let root = try folder([".claude/CLAUDE.md": "# Claude\n"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(try AgentsInit(root: root).install(answer: nil).changed == [".claude/CLAUDE.md"])
        #expect(read(root, ".claude/CLAUDE.md") == "# Claude\n\n" + Self.block)
    }

    @Test func withNeitherFileTheDecisionRecommendsTheAgentsFileAndAClaudeFileThatImportsIt() throws {
        let root = try folder([:])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let decision = try #require(AgentsInit(root: root).decision)
        #expect(decision.key == "agents" && decision.options == ["both", "AGENTS.md", "CLAUDE.md", "none"] && decision.recommended == "both")
        let done = try AgentsInit(root: root).install(answer: nil)
        #expect(read(root, "AGENTS.md") == Self.block && read(root, "CLAUDE.md") == "@AGENTS.md\n")
        #expect(done.lines == ["AGENTS.md: created with xcd's block", "CLAUDE.md: created, importing AGENTS.md"])
    }

    @Test func anAnswerPicksTheFileInAnyCaseAndNoneWritesNothing() throws {
        let claude = try folder([:])
        defer { try? FileManager.default.removeItem(atPath: claude) }
        #expect(try AgentsInit(root: claude).install(answer: "claude.md").changed == ["CLAUDE.md"])
        #expect(read(claude, "CLAUDE.md") == Self.block && read(claude, "AGENTS.md") == nil)
        let none = try folder(["CLAUDE.md": "# Ours\n"])
        defer { try? FileManager.default.removeItem(atPath: none) }
        #expect(try AgentsInit(root: none).install(answer: "none") == AgentsInstall())
        #expect(read(none, "CLAUDE.md") == "# Ours\n")
        #expect(throws: XcdError.self) { try AgentsInit(root: none).install(answer: "README.md") }
    }

    @Test func handWrittenXcdLinesAndBrokenMarkersAreWarnedAbout() throws {
        let root = try folder(["CLAUDE.md": "- Build with `xcd build --scheme SampleAgent`.\n", "AGENTS.md": "<!-- xcd:begin: x -->\nhalf\n"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let done = try AgentsInit(root: root).install(answer: nil)
        #expect(done.changed == ["CLAUDE.md"] && read(root, "AGENTS.md") == "<!-- xcd:begin: x -->\nhalf\n")
        #expect(done.warnings == [
            "AGENTS.md has an xcd begin marker with no end marker after it, so xcd left it alone: fix the markers by hand",
            "CLAUDE.md also mentions xcd outside xcd's block: show the user those lines, and ask which to keep; "
                + "the block now says what xcd needs agents to know"])
    }

    @Test func aCurrentBlockIsLeftAsItIs() throws {
        let root = try folder(["CLAUDE.md": "# Ours\n\n" + Self.block])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let done = try AgentsInit(root: root).install(answer: nil)
        #expect(done.changed.isEmpty && done.lines == ["CLAUDE.md: xcd's block is current"])
        #expect(AgentsReport(agents: done).text == "CLAUDE.md: xcd's block is current")
    }

    @Test func initAgentsInAProjectWithNeitherFileAsksForTheAnswer() async throws {
        let (project, service) = try InitServiceTests().setup()
        defer { project.remove() }
        let error = await #expect(throws: XcdError.self) { try await service.installAgents(answers: [:], from: project.root) }
        #expect(error?.code == .usage && error?.message == "this project has neither AGENTS.md nor CLAUDE.md")
        #expect(error?.next == "ask the user which files should hold xcd's block, then run "
                    + "`xcd init --agents --set agents=<both|AGENTS.md|CLAUDE.md>`")
        let report = try await service.installAgents(answers: ["agents": "both"], from: project.root)
        #expect(report.text == "AGENTS.md: created with xcd's block\nCLAUDE.md: created, importing AGENTS.md\ncommit AGENTS.md and CLAUDE.md")
        #expect(!FileManager.default.fileExists(atPath: project.root + "/.xcdev.yml"))
        await #expect(throws: XcdError.self) { try await service.installAgents(answers: ["xcode": "system"], from: project.root) }
    }

    @Test func initWritesTheBlockAndSaysWhatToCommit() async throws {
        let (project, service) = try InitServiceTests().setup()
        defer { project.remove() }
        try project.write("# Ours\n", to: "CLAUDE.md")
        let report = try await service.write(answers: [:], force: false, from: project.root)
        #expect(read(project.root, "CLAUDE.md") == "# Ours\n\n" + Self.block)
        let lines = report.text.components(separatedBy: "\n")
        #expect(lines.contains("CLAUDE.md: added xcd's block"))
        #expect(lines.contains("commit .xcdev.yml, .gitignore, and CLAUDE.md"))
        await #expect(throws: XcdError.self) { try await service.write(answers: ["agents": "README.md"], force: true, from: project.root) }
    }

    @Test func aByteOrderMarkIsKept() throws {
        let root = try folder([:])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mark = Data([0xEF, 0xBB, 0xBF])
        try (mark + Data("# Ours\n".utf8)).write(to: URL(fileURLWithPath: root + "/CLAUDE.md"))
        _ = try AgentsInit(root: root).install(answer: nil)
        let written = try Data(contentsOf: URL(fileURLWithPath: root + "/CLAUDE.md"))
        #expect(written == mark + Data(("# Ours\n\n" + Self.block).utf8))
    }

    @Test func aLinkIsWrittenThroughAndNotReplaced() throws {
        let root = try folder(["CLAUDE.md": "# Ours\n"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createSymbolicLink(atPath: root + "/AGENTS.md", withDestinationPath: "CLAUDE.md")
        let done = try AgentsInit(root: root).install(answer: nil)
        #expect(done.changed == ["CLAUDE.md"] && done.lines == ["CLAUDE.md: added xcd's block"])
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: root + "/AGENTS.md")) == "CLAUDE.md")
        let text = read(root, "CLAUDE.md") ?? ""
        #expect(text == "# Ours\n\n" + Self.block)
    }

    @Test func aLinkOutOfTheCheckoutIsLeftAlone() throws {
        let other = try folder(["rules.md": "# Shared\n"])
        let root = try folder([:])
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: other) }
        try FileManager.default.createSymbolicLink(atPath: root + "/AGENTS.md", withDestinationPath: other + "/rules.md")
        let done = try AgentsInit(root: root).install(answer: nil)
        #expect(read(other, "rules.md") == "# Shared\n" && done.changed.isEmpty && done.lines.isEmpty)
        #expect(done.warnings.count == 1 && done.warnings[0].hasPrefix("AGENTS.md is a link to ")
                && done.warnings[0].hasSuffix(", outside this checkout, so xcd left it alone: ask the user whether xcd's block belongs there"))
    }

    @Test func aDanglingLinkIsNotReplaced() throws {
        let root = try folder([:])
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createSymbolicLink(atPath: root + "/AGENTS.md", withDestinationPath: "missing.md")
        let done = try AgentsInit(root: root).install(answer: nil)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: root + "/AGENTS.md")) == "missing.md")
        #expect(!FileManager.default.fileExists(atPath: root + "/CLAUDE.md") && done.changed.isEmpty && done.warnings.count == 1)
    }

    @Test func aReadOnlyFileIsLeftWithAWarning() throws {
        let root = try folder(["CLAUDE.md": "# Ours\n"])
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: root + "/CLAUDE.md")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root + "/CLAUDE.md")
            try? FileManager.default.removeItem(atPath: root)
        }
        let done = try AgentsInit(root: root).install(answer: nil)
        #expect(read(root, "CLAUDE.md") == "# Ours\n" && done.changed.isEmpty)
        #expect(done.warnings == ["xcd could not write CLAUDE.md, so it left it as it was"])
    }

    @Test func aFileThatCannotBeCreatedIsAWarning() throws {
        let root = try folder([:])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root)
            try? FileManager.default.removeItem(atPath: root)
        }
        let done = try AgentsInit(root: root).install(answer: "both")
        #expect(done.changed.isEmpty && !FileManager.default.fileExists(atPath: root + "/AGENTS.md"))
        #expect(done.warnings == ["xcd could not create AGENTS.md, so it left it out", "xcd could not create CLAUDE.md, so it left it out"])
    }

    @Test func anAnswerThatDoesNotApplyIsRefused() async throws {
        let root = try folder(["CLAUDE.md": "# Ours\n"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let error = #expect(throws: XcdError.self) { try AgentsInit(root: root).install(answer: "AGENTS.md") }
        #expect(error?.code == .usage && error?.next == "leave out agents to put xcd's block in the files it has, or use agents=none for none")
        #expect(error?.message == "agents=AGENTS.md applies only to a project with neither AGENTS.md nor CLAUDE.md, and this one has CLAUDE.md")
        #expect(try AgentsInit(root: root).install(answer: "none") == AgentsInstall())
        let (project, service) = try InitServiceTests().setup()
        defer { project.remove() }
        try project.write("# Ours\n", to: "CLAUDE.md")
        await #expect(throws: XcdError.self) { try await service.write(answers: ["agents": "both"], force: false, from: project.root) }
        #expect(!FileManager.default.fileExists(atPath: project.root + "/.xcdev.yml"))
    }

    @Test func forceWithoutAnAnswerMakesNoAgentFileAndSaysHowToMakeThem() async throws {
        let (project, service) = try InitServiceTests().setup()
        defer { project.remove() }
        _ = try await service.write(answers: ["agents": "none"], force: false, from: project.root)
        let report = try await service.write(answers: [:], force: true, from: project.root)
        #expect(read(project.root, "AGENTS.md") == nil && read(project.root, "CLAUDE.md") == nil)
        #expect(report.text.components(separatedBy: "\n").contains("no AGENTS.md or CLAUDE.md was made; "
            + "`xcd init --agents --set agents=<both|AGENTS.md|CLAUDE.md>` makes them"))
        _ = try await service.write(answers: ["agents": "both"], force: true, from: project.root)
        #expect(read(project.root, "AGENTS.md") == Self.block && read(project.root, "CLAUDE.md") == "@AGENTS.md\n")
    }

    @Test func forceWithDefaultsTakesEveryRecommendationBothFilesIncluded() async throws {
        let (project, service) = try InitServiceTests().setup()
        defer { project.remove() }
        _ = try await service.write(answers: ["agents": "none"], force: false, from: project.root)
        _ = try await service.write(answers: [:], force: true, defaults: true, from: project.root)
        #expect(read(project.root, "AGENTS.md") == Self.block && read(project.root, "CLAUDE.md") == "@AGENTS.md\n")
    }
}
