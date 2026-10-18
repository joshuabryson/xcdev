import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Doctor keeps xcd's block in AGENTS.md and CLAUDE.md as this xcd writes it.
@Suite struct AgentDocsCheckTests {
    let quality = QualityChecksTests()
    static let old = "<!-- xcd:begin: written by an older xcd -->\nUse xcd wt create.\n<!-- xcd:end -->"

    func read(_ project: TempProject, _ file: String) throws -> String {
        try String(contentsOfFile: project.root + "/" + file, encoding: .utf8)
    }

    @Test func aCurrentBlockAndAFileWithoutOneAreNotProblems() async throws {
        let project = try quality.setup()
        defer { project.remove() }
        try project.write("# Ours\n\n" + AgentBlock.text + "\n", to: "CLAUDE.md")
        try project.write("# Agents, with `xcd build` in our own words\n", to: "AGENTS.md")
        let report = await quality.doctor(project).run(fix: false, checks: [AgentDocsCheck()], from: project.root)
        #expect(report.problems.isEmpty && report.text.contains("ok       agent-docs"))
    }

    @Test func aDifferingBlockIsAProblemThatFixRewritesKeepingTheRestOfTheFile() async throws {
        let project = try quality.setup()
        defer { project.remove() }
        try project.write("# Ours\n\n" + Self.old + "\n\n## After\n", to: "CLAUDE.md")
        let report = await quality.doctor(project).run(fix: false, checks: [AgentDocsCheck()], from: project.root)
        #expect(report.problems == [
            DoctorProblem(check: "agent-docs", message: "CLAUDE.md's xcd block differs from this xcd's", action: .rewriteAgentBlock,
                          fix: "rewrite it", subject: project.root + "/CLAUDE.md", done: "rewrote it; the change is yours to commit")
                .inProject(project.root)])
        #expect(report.text.contains("problem  agent-docs  CLAUDE.md's xcd block differs from this xcd's  (--fix: rewrite it)"))

        try project.write("# Ours, edited and not committed\n\n" + Self.old + "\n\n## After\n", to: "CLAUDE.md")
        let fixed = await quality.doctor(project).run(fix: true, checks: [AgentDocsCheck()], from: project.root)
        #expect(fixed.problems.map(\.fixed) == [true] && fixed.failure == nil)
        #expect(try read(project, "CLAUDE.md") == "# Ours, edited and not committed\n\n" + AgentBlock.text + "\n\n## After\n")
    }

    @Test func aBeginMarkerWithNoEndIsAProblemWithoutAFix() async throws {
        let project = try quality.setup()
        defer { project.remove() }
        try project.write("<!-- xcd:begin: x -->\nhalf\n", to: "AGENTS.md")
        let report = await quality.doctor(project).run(fix: true, checks: [AgentDocsCheck()], from: project.root)
        let problem = try #require(report.problems.first)
        #expect(problem.action == nil && !problem.fixed && problem.next == "fix the xcd markers in AGENTS.md by hand")
        #expect(try read(project, "AGENTS.md") == "<!-- xcd:begin: x -->\nhalf\n")
    }

    @Test func theCheckDoesNotRunWhenDoctorCannotTellWhichProjectItIsIn() async throws {
        let project = try quality.setup()
        defer { project.remove() }
        let worktrees = WorktreeService(runner: RoutingRunner(fake: quality.shared.fake), globalPaths: GlobalPaths(base: project.home))
        let (feat, _) = try await worktrees.create(name: "feat", in: try await worktrees.open(from: project.root))
        try project.write(Self.old + "\n", to: "CLAUDE.md", in: feat.path)
        try FileManager.default.moveItem(atPath: project.root, toPath: project.base + "/Moved App")
        let report = await quality.doctor(project).run(fix: true, checks: [AgentDocsCheck()], from: feat.path)
        #expect(!report.checks.contains { $0.id == "agent-docs" })
        #expect(try String(contentsOfFile: feat.path + "/CLAUDE.md", encoding: .utf8) == Self.old + "\n")
    }

    @Test func aFixKeepsAByteOrderMarkAndALink() async throws {
        let project = try quality.setup()
        defer { project.remove() }
        let mark = Data([0xEF, 0xBB, 0xBF])
        try (mark + Data(("# Ours\n\n" + Self.old + "\n").utf8)).write(to: URL(fileURLWithPath: project.root + "/CLAUDE.md"))
        try FileManager.default.createSymbolicLink(atPath: project.root + "/AGENTS.md", withDestinationPath: "CLAUDE.md")
        let report = await quality.doctor(project).run(fix: true, checks: [AgentDocsCheck()], from: project.root)
        #expect(report.problems.map(\.fixed) == [true])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: project.root + "/CLAUDE.md"))
        #expect(bytes == mark + Data(("# Ours\n\n" + AgentBlock.text + "\n").utf8))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: project.root + "/AGENTS.md")) == "CLAUDE.md")
    }

    @Test func aFileOutsideTheCheckoutIsNotDoctorsAndALinkIsReportedOnce() async throws {
        let project = try quality.setup()
        defer { project.remove() }
        let outside = project.base + "/shared-rules.md"
        try (Self.old + "\n").write(toFile: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: project.root + "/AGENTS.md", withDestinationPath: outside)
        let first = await quality.doctor(project).run(fix: true, checks: [AgentDocsCheck()], from: project.root)
        #expect(first.problems.isEmpty)
        #expect(try String(contentsOfFile: outside, encoding: .utf8) == Self.old + "\n")

        try FileManager.default.removeItem(atPath: project.root + "/AGENTS.md")
        try project.write(Self.old + "\n", to: "CLAUDE.md")
        try FileManager.default.createSymbolicLink(atPath: project.root + "/AGENTS.md", withDestinationPath: "CLAUDE.md")
        let second = await quality.doctor(project).run(fix: false, checks: [AgentDocsCheck()], from: project.root)
        #expect(second.problems.map(\.message) == ["CLAUDE.md's xcd block differs from this xcd's"])
    }

    @Test func theFixLeavesAFileThatChangedSinceDetectAlone() async throws {
        let project = try quality.setup()
        defer { project.remove() }
        try project.write(Self.old + "\n", to: "CLAUDE.md")
        let env = await quality.doctor(project).environment(from: project.root, fixing: true)
        let problem = try #require(AgentDocsCheck().detect(env).first)
        let changes = [
            (AgentBlock.text + "\n", "CLAUDE.md's xcd block is this xcd's now; left alone"),
            ("# Ours, no block\n", "CLAUDE.md's xcd block is gone now; left alone"),
            ("<!-- xcd:begin: x -->\nhalf\n", "CLAUDE.md's xcd end marker is gone now; left alone")]
        for (text, note) in changes {
            try project.write(text, to: "CLAUDE.md")
            #expect(throws: DoctorLeftAlone(note: note)) { try AgentDocsCheck().fix(problem, env) }
            #expect(try read(project, "CLAUDE.md") == text)
        }
        let outside = project.base + "/shared-rules.md"
        try (Self.old + "\n").write(toFile: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: project.root + "/CLAUDE.md")
        try FileManager.default.createSymbolicLink(atPath: project.root + "/CLAUDE.md", withDestinationPath: outside)
        #expect(throws: DoctorLeftAlone(note: "CLAUDE.md leads outside this checkout now; left alone")) {
            try AgentDocsCheck().fix(problem, env)
        }
        #expect(try String(contentsOfFile: outside, encoding: .utf8) == Self.old + "\n")
    }

    @Test func aBlockInTheClaudeFolderIsReportedByItsName() async throws {
        let project = try quality.setup()
        defer { project.remove() }
        try project.write(Self.old + "\n", to: ".claude/CLAUDE.md")
        let report = await quality.doctor(project).run(fix: false, checks: [AgentDocsCheck()], from: project.root)
        #expect(report.problems.map(\.message) == [".claude/CLAUDE.md's xcd block differs from this xcd's"])
    }
}
