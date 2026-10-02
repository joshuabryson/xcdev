import Foundation
import Testing
@testable import XcdevKit

@Suite struct GuidesTests {
    static let guidesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/agents/guides").path

    /// The embedded guides are generated from docs/agents/guides; this fails until `scripts/embed-guides.sh` is re-run.
    @Test func embeddedGuidesMatchTheMarkdownInTheRepo() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.guidesDirectory).filter { $0.hasSuffix(".md") }.sorted()
        #expect(Guides.all.map(\.topic) == files.map { String($0.dropLast(3)) })
        for file in files {
            let markdown = try String(contentsOfFile: Self.guidesDirectory + "/" + file, encoding: .utf8)
            let guide = try Guides.guide(String(file.dropLast(3)))
            #expect(guide.markdown + "\n" == markdown, "run scripts/embed-guides.sh: \(file) changed")
        }
    }

    @Test func setupGuideWalksThroughInitPlanAndExplain() throws {
        let guide = try Guides.guide("setup")
        #expect(guide.summary == "Set up xcd in a project")
        for step in ["xcd init --plan", "xcd config explain", "xcd init --set", "xcd init --defaults", "xcd config show", "xcd doctor"] {
            #expect(guide.markdown.contains(step), "setup guide doesn't mention \(step)")
        }
        // The reference covers every top-level section of the config.
        guard case .object(_, let fields) = ConfigSchema.v1 else { return }
        for field in fields where field.name != "version" {
            #expect(guide.markdown.contains("| `\(field.name)` |"), "setup guide has no row for \(field.name)")
        }
    }

    @Test func listingAndUnknownTopic() throws {
        #expect(try GuideReport(topic: nil).text == "setup  Set up xcd in a project\nread one: xcd guide <topic>")
        #expect(try GuideReport(topic: "setup").text.hasPrefix("# Set up xcd in a project\n"))
        let error = #expect(throws: XcdError.self) { try Guides.guide("setpu") }
        #expect(error?.code == .usage)
        #expect(error?.next == "did you mean `xcd guide setup`?")
    }
}
