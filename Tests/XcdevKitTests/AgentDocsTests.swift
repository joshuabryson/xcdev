import Foundation
import Testing
@testable import XcdevKit

@Suite struct AgentDocsTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().path

    /// Every `xcd <command>` the agent-facing docs mention is a real command, so they can't drift from the CLI.
    @Test(arguments: ["docs/agents/AGENTS-snippet.md", "skills/xcdev/SKILL.md", "README.md", "docs/agents/guides/setup.md",
                      "docs/agents/guides/ui.md", "docs/agents/guides/deeplinks.md", "docs/agents/guides/quality.md"])
    func docsOnlyNameRealCommands(_ file: String) throws {
        let text = try String(contentsOfFile: Self.repo + "/" + file, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: "`xcd ([a-z-]+)")
        let names = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
        #expect(!names.isEmpty)
        let unknown = Set(names).subtracting(BuiltinCommands.reservedNames)
        #expect(unknown.isEmpty, "\(file) mentions unknown commands: \(unknown.sorted())")
    }

    /// An agent that has never seen the project finds `xcd open` from each of these.
    @Test(arguments: ["docs/agents/AGENTS-snippet.md", "skills/xcdev/SKILL.md", "README.md", "docs/agents/guides/ui.md"])
    func theDocsPointAtRoutes(_ file: String) throws {
        let text = try String(contentsOfFile: Self.repo + "/" + file, encoding: .utf8)
        #expect(text.contains("`xcd open") && text.contains("`xcd guide deeplinks`"), "\(file) doesn't mention xcd open and its guide")
    }

    /// An agent that has never seen the project finds `xcd lint` from each of these.
    @Test(arguments: ["docs/agents/AGENTS-snippet.md", "skills/xcdev/SKILL.md", "README.md"])
    func theDocsPointAtLint(_ file: String) throws {
        let text = try String(contentsOfFile: Self.repo + "/" + file, encoding: .utf8)
        #expect(text.contains("`xcd lint") && text.contains("`xcd guide quality`"), "\(file) doesn't mention xcd lint and its guide")
    }

    /// An agent that has never seen the project finds `xcd format` from each of these, before `xcd lint`.
    @Test(arguments: ["docs/agents/AGENTS-snippet.md", "skills/xcdev/SKILL.md", "README.md", "docs/agents/guides/quality.md"])
    func theDocsPointAtFormatBeforeLint(_ file: String) throws {
        let text = try String(contentsOfFile: Self.repo + "/" + file, encoding: .utf8)
        let format = try #require(text.range(of: "xcd format"), "\(file) doesn't mention xcd format")
        let lint = try #require(text.range(of: "xcd lint"))
        #expect(format.lowerBound < lint.lowerBound, "\(file) names xcd lint before xcd format")
    }

    @Test func theSkillHasFrontMatter() throws {
        let text = try String(contentsOfFile: Self.repo + "/skills/xcdev/SKILL.md", encoding: .utf8)
        #expect(text.hasPrefix("---\nname: xcdev\ndescription: "))
    }

    @Test func theFormulaTemplateInstallsTheAlias() throws {
        let text = try String(contentsOfFile: Self.repo + "/packaging/homebrew/xcdev.rb.template", encoding: .utf8)
        for placeholder in ["@VERSION@", "@SHA256@", "@REPOSITORY@"] { #expect(text.contains(placeholder)) }
        #expect(text.contains(#"bin.install_symlink "xcd" => "xcdev""#))
    }
}
