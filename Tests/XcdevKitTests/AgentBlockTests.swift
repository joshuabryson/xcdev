import Foundation
import Testing
@testable import XcdevKit

/// xcd's block in AGENTS.md and CLAUDE.md.
@Suite struct AgentBlockTests {
    static let block = AgentBlock.text

    @Test func theBlockIsTheSnippetInTheRepo() throws {
        let file = try String(contentsOfFile: AgentDocsTests.repo + "/docs/agents/AGENTS-snippet.md", encoding: .utf8)
        #expect(Self.block + "\n" == file, "run scripts/embed-guides.sh: docs/agents/AGENTS-snippet.md changed")
        #expect(Self.block.hasPrefix(AgentBlock.begin) && Self.block.hasSuffix(AgentBlock.end))
    }

    @Test func itIsAppendedAfterOneBlankLine() {
        #expect(AgentBlock.written(into: "# App\n") == "# App\n\n" + Self.block + "\n")
        #expect(AgentBlock.written(into: "# App") == "# App\n\n" + Self.block + "\n")
        #expect(AgentBlock.written(into: "") == Self.block + "\n")
        #expect(AgentBlock.written(into: "# App\n\n") == "# App\n\n" + Self.block + "\n")
    }

    @Test func anOlderBlockIsReplacedAndEveryByteAroundItKept() {
        let file = "# App\nlines of our own\n\n<!-- xcd:begin: old -->\nold text\n<!-- xcd:end -->\n\n## After\nmore\n"
        #expect(AgentBlock.written(into: file) == "# App\nlines of our own\n\n" + Self.block + "\n\n## After\nmore\n")
        #expect(!AgentBlock.isCurrent(in: file))
        #expect(AgentBlock.isCurrent(in: AgentBlock.written(into: file) ?? ""))
    }

    @Test func aCRLFFileGetsTheBlockWithItsOwnLineEndings() throws {
        let file = "# App\r\nours\r\n"
        let written = try #require(AgentBlock.written(into: file))
        #expect(written == file + "\r\n" + Self.block.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n")
        #expect(AgentBlock.isCurrent(in: written) && AgentBlock.written(into: written) == written)
        #expect(AgentBlock.written(into: "a\nb\r\n") == "a\nb\r\n\n" + Self.block + "\n")
        #expect(AgentBlock.written(into: "a\u{2028}b\n") == "a\u{2028}b\n\n" + Self.block + "\n")
        let lone = "a\rb\r"
        let loneWritten = try #require(AgentBlock.written(into: lone))
        #expect(loneWritten == lone + "\r" + Self.block.replacingOccurrences(of: "\n", with: "\r") + "\r")
        #expect(AgentBlock.isCurrent(in: loneWritten) && AgentBlock.written(into: loneWritten) == loneWritten)
    }

    @Test func aBeginMarkerWithNoEndIsLeftAlone() {
        let file = "# App\n<!-- xcd:begin: written by xcd -->\nhalf\n"
        #expect(AgentBlock.find(in: file) == .unclosed && AgentBlock.written(into: file) == nil)
        let mention = "<!-- xcd:begin: old -->\nold\nours\nWrite `<!-- xcd:end -->` to close it.\nmore\n"
        #expect(AgentBlock.find(in: mention) == .unclosed && AgentBlock.written(into: mention) == nil)
    }

    @Test func aMarkerInsideALineIsNotTheBlock() {
        #expect(AgentBlock.find(in: "Write `<!-- xcd:begin` to start one.\n") == .none)
        let file = "See `<!-- xcd:begin` below.\n\n<!-- xcd:begin: old -->\nold\n<!-- xcd:end -->\n"
        #expect(AgentBlock.written(into: file) == "See `<!-- xcd:begin` below.\n\n" + Self.block + "\n")
    }

    @Test func mentionsOfXcdOutsideTheBlockAreFound() throws {
        let alone = try #require(AgentBlock.written(into: "# App\n"))
        #expect(!AgentBlock.mentionsXcdOutside(alone))
        #expect(AgentBlock.mentionsXcdOutside(alone + "- Build with `xcd build --scheme SampleAgent`.\n"))
        #expect(AgentBlock.mentionsXcdOutside("Configured by .xcdev.yml.\n"))
    }

    @Test func aClaudeFileThatImportsAgentsMdIsRecognised() {
        #expect(AgentBlock.importsAgentsFile("# Claude\n@AGENTS.md\n") && AgentBlock.importsAgentsFile("@./AGENTS.md"))
        #expect(!AgentBlock.importsAgentsFile("See AGENTS.md for the rest.\n"))
        #expect(AgentBlock.importsAgentsFile("@../AGENTS.md\n", from: ".claude/CLAUDE.md"))
        #expect(!AgentBlock.importsAgentsFile("@AGENTS.md\n", from: ".claude/CLAUDE.md"))
    }
}
