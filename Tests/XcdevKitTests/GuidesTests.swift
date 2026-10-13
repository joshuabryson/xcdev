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

    /// The guide names every `xcd ui` driving command, every target form, and every error an agent can get from them.
    @Test func uiGuideCoversTheCommandsTargetsAndErrors() throws {
        let guide = try Guides.guide("ui")
        #expect(guide.summary == "See and drive the app's UI")
        for command in ["tree", "tap", "long-press", "type", "swipe", "button", "rotate", "wait", "screenshot", "stop"] {
            #expect(guide.markdown.contains("`xcd ui \(command)"), "the ui guide doesn't mention xcd ui \(command)")
        }
        for form in ["`id:<identifier>`", "`label:<text>`", "`label~<text>`", "`ref:e<N>`", "`@x,y`", "--tree", "--system", "--bundle"] {
            #expect(guide.markdown.contains(form), "the ui guide doesn't mention \(form)")
        }
        let codes: [ErrorCode] = [.elementNotFound, .elementNotHittable, .elementAmbiguous, .staleRef, .waitTimeout, .appCrashed, .runnerFailed]
        for code in codes {
            #expect(guide.markdown.contains("| `\(code.rawValue)` |"), "the ui guide has no row for \(code.rawValue)")
        }
    }

    /// The guide names each kind of route, every key and flag, the script's variables, and every error `xcd open` gives.
    @Test func deeplinksGuideCoversRoutesFlagsAndErrors() throws {
        let guide = try Guides.guide("deeplinks")
        #expect(guide.summary == "Open the app's links and routes")
        for key in ["`url`", "`launch`", "`run`", "`params`", "`preset`", "`expect`", "`timeout`", "`vars`", "`values`", "`default`",
                    "`optional`", "raw: true"] {
            #expect(guide.markdown.contains(key), "the deeplinks guide doesn't mention \(key)")
        }
        for word in ["--cold", "--dry-run", "--device \"$XCD_DEVICE\"", "`XCD_ROUTE`", "`XCD_PARAM_<NAME>`", "`xcd sim open-url`",
                     "onOpenURL", "CFBundleURLTypes", "applinks:", ".xcdev.local.yml", "`check: inconclusive`", "NSUserActivity"] {
            #expect(guide.markdown.contains(word), "the deeplinks guide doesn't mention \(word)")
        }
        // What an agent would otherwise learn by failing: the first check is slow, how to get past an inconclusive one,
        // that opening the route again after a runner failure sends the link twice, and that a script must be executable.
        for advice in ["builds the UI runner once", "For a definite answer", "sends the link a second time", "chmod +x scripts/open-about.sh"] {
            #expect(guide.markdown.contains(advice), "the deeplinks guide doesn't say: \(advice)")
        }
        for state in [AppArrival.running, .started, .restarted, .startedByLink, .untouched] {
            #expect(guide.markdown.contains("`\(state.rawValue)`"), "the deeplinks guide doesn't explain app=\(state.rawValue)")
        }
        let codes: [ErrorCode] = [.usage, .configInvalid, .appNotBuilt, .platformUnsupported, .appCrashed, .waitTimeout, .routeFailed,
                                  .runnerFailed]
        for code in codes {
            #expect(guide.markdown.contains("| `\(code.rawValue)` |"), "the deeplinks guide has no row for \(code.rawValue)")
        }
    }

    /// The guide names each scope, says which findings to leave alone, and has a row for every way lint can fail to run.
    @Test func qualityGuideCoversTheScopesTheResultAndTheErrors() throws {
        let guide = try Guides.guide("quality")
        #expect(guide.summary == "Lint the code you changed")
        for word in ["`xcd lint`", "xcd lint --files", "xcd lint --all", "--base <ref>", "tool: swiftlint", #"run: ./scripts/lint.sh "$@""#,
                     "`.swiftlint.yml`", "`.xcdev.local.yml`", "`xcd doctor --fix`", "`xcd config explain lint`", "(lint.tool is none)",
                     "older findings"] {
            #expect(guide.markdown.contains(word), "the quality guide doesn't mention \(word)")
        }
        // What an agent would otherwise get wrong: fixing findings that were there before, choosing a linter for the
        // user, installing one, and trusting findings made with the linter's default rules.
        for advice in ["Leave the older ones alone", "theirs to decide", "Do not install it yourself", "on a line you did not touch",
                       "its default rules", #"one with no `"$@"` gets no files"#] {
            #expect(guide.markdown.contains(advice), "the quality guide doesn't say: \(advice)")
        }
        for code in [ErrorCode.notConfigured, .toolMissing, .lintFailed, .usage, .configInvalid, .subprocessFailed] {
            #expect(guide.markdown.contains("| `\(code.rawValue)` |"), "the quality guide has no row for \(code.rawValue)")
        }
        #expect(try Guides.guide("setup").markdown.contains("`lint.tool`"))
    }

    @Test func listingAndUnknownTopic() throws {
        #expect(try GuideReport(topic: nil).text == """
        deeplinks  Open the app's links and routes
        quality    Lint the code you changed
        setup      Set up xcd in a project
        ui         See and drive the app's UI
        read one: xcd guide <topic>
        """)
        #expect(try GuideReport(topic: "setup").text.hasPrefix("# Set up xcd in a project\n"))
        let error = #expect(throws: XcdError.self) { try Guides.guide("setpu") }
        #expect(error?.code == .usage)
        #expect(error?.next == "did you mean `xcd guide setup`?")
    }
}
