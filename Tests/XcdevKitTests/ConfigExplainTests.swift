import Foundation
import Testing
import Yams
@testable import XcdevKit

@Suite struct ConfigExplainTests {
    @Test func everyKeyHasADescriptionAndAnExampleThatValidates() throws {
        let docs = ConfigExplainer.keys()
        #expect(docs.count > 20)
        for doc in docs {
            #expect(!doc.summary.isEmpty, "no description for \(doc.key)")
            #expect(!doc.example.isEmpty, "no example for \(doc.key)")
            // Every example is a valid fragment of .xcdev.yml, so it can't drift from the schema.
            let node = try #require(try Yams.compose(yaml: doc.example), "example for \(doc.key) is not YAML")
            let issues = SchemaValidator.validate(node, against: ConfigSchema.v1, checkRequired: false)
            #expect(issues.isEmpty, "example for \(doc.key): \(issues.map(\.line))")
        }
    }

    @Test func explainsANamedKeyGivenAnyName() throws {
        let doc = try ConfigExplainer.explain("devices.iphone.runtime")
        #expect(doc.key == "devices.<name>.runtime")
        #expect(doc.defaultValue == "latest (the newest installed runtime this Xcode supports)")
        #expect(try ConfigExplainer.explain("devices.<name>.runtime") == doc)
        #expect(try ConfigExplainer.explain("hooks.pre-build").type == "string")
        #expect(try ConfigExplainer.explain("commands.seed-db.needs").type == "list of strings")
    }

    @Test func explainText() throws {
        #expect(try ConfigExplainReport(key: "devices.mac.platform").text == """
        devices.<name>.platform (string)
        Set to macOS for Mac apps. They build and run natively and have no simulator.
        allowed: macOS
        example:
          devices:
            mac: { platform: macOS }
        """)
        let section = try ConfigExplainReport(key: "schemes")
        #expect(section.text.hasSuffix("keys: schemes.app, schemes.test"))
        #expect(try ConfigExplainReport(key: "commands.x.run").text.hasPrefix("commands.<name>.run (string, required)\n"))
    }

    @Test func listingShowsEveryKeyOnOneLine() throws {
        let text = try ConfigExplainReport(key: nil).text
        let lines = text.split(separator: "\n")
        #expect(lines.count == ConfigExplainer.keys().count + 1)
        #expect(lines.first?.hasPrefix("version ") == true)
        #expect(lines.last == "details: xcd config explain <key>")
    }

    @Test func unknownKeySuggestsClosest() {
        let error = #expect(throws: XcdError.self) { try ConfigExplainer.explain("defaultDevise") }
        #expect(error?.code == .usage)
        #expect(error?.next == "did you mean `defaultDevice`? `xcd config explain` lists every key")
    }

    @Test func uiKeysAreExplained() throws {
        let dir = try ConfigExplainer.explain("ui.media.dir")
        #expect(dir.type == "string" && dir.defaultValue == ".xcdev-media/{worktree}/{branch}")
        #expect(dir.summary.contains("{branch}") && dir.summary.contains("main checkout"))
        #expect(try ConfigExplainer.explain("ui.record.maxDuration").defaultValue == "10m")
        #expect(!ConfigSchema.reservedTopLevelKeys.contains("ui"))
    }

    @Test func isolationIsExplainedWithItsValuesAndItsDefault() throws {
        #expect(try ConfigExplainReport(key: "devices.mac.isolation").text == """
        devices.<name>.isolation (string)
        Mac apps only. shared (the default) runs the built app with its real bundle id, so every worktree's copy and the user's installed copy share its data; suffix launches a re-signed copy whose bundle id ends in .xcd-<worktree>, so each worktree keeps its own data, for an app that needs no provisioning profile.
        allowed: shared, suffix
        default: shared
        example:
          devices:
            mac: { platform: macOS, isolation: suffix }
        """)
    }
}
