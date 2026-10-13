import Foundation
import Testing
@testable import XcdevKit

@Suite struct QualityConfigTests {
    /// A config whose `lint:` section (or `section`) holds `lines`, each written as it stands under the key
    /// (indented two spaces).
    static func config(_ lines: String, section: String = "lint") -> String {
        "version: 1\nproject: App.xcodeproj\n\(section):\n\(lines)\n"
    }

    /// What the loader says about a section that holds `lines`, one line per problem. Empty when it loads.
    static func issues(_ lines: String, section: String) -> [String] {
        do {
            _ = try ConfigLoader.parse(main: config(lines, section: section))
            return []
        } catch {
            return (error as? XcdError)?.details ?? ["\(error)"]
        }
    }

    func issues(_ lines: String) -> [String] { Self.issues(lines, section: "lint") }

    @Test func aNamedToolLoadsWithItsPathAndArguments() throws {
        let config = try ConfigLoader.parse(main: Self.config("  tool: swiftlint\n  path: tools/swiftlint\n  args: [\"--strict\"]"))
        #expect(config.lint == LintConfig(tool: .swiftlint, path: "tools/swiftlint", args: ["--strict"]))
        #expect(config.lintSetup == .swiftlint(path: "tools/swiftlint", args: ["--strict"]))
    }

    @Test func aProjectsOwnCommandLoads() throws {
        let config = try ConfigLoader.parse(main: Self.config("  run: ./scripts/lint.sh --quiet"))
        #expect(config.lintSetup == .command("./scripts/lint.sh --quiet"))
    }

    @Test func theSectionHasThreeStates() throws {
        let absent = try ConfigLoader.parse(main: "version: 1\nproject: App.xcodeproj\n")
        #expect(absent.lintSetup == .absent)
        #expect(try ConfigLoader.parse(main: Self.config("  tool: none")).lintSetup == .off)
        #expect(try ConfigLoader.parse(main: Self.config("  tool: swiftlint")).lintSetup == .swiftlint(path: nil, args: []))
    }

    @Test func aSectionHasExactlyOneOfToolAndRun() {
        #expect(issues("  tool: swiftlint\n  run: ./lint.sh") == ["lint: has tool and run; a section has exactly one of them"])
        #expect(issues("  args: [\"--strict\"]") == ["lint: needs one of tool or run",
                                                   "lint.args: is only read with a tool other than none"])
        #expect(issues("  {}") == ["lint: needs one of tool or run"])
    }

    @Test func pathAndArgsGoWithAToolThatRuns() {
        #expect(issues("  tool: none\n  path: tools/swiftlint") == ["lint.path: is only read with a tool other than none"])
        #expect(issues("  run: ./lint.sh\n  args: [\"-x\"]") == ["lint.args: is only read with a tool other than none"])
    }

    @Test func anEmptyRunOrPathIsRefused() {
        #expect(issues("  run: \"  \"") == ["lint.run: must not be empty"])
        #expect(issues("  tool: swiftlint\n  path: \"\"") == ["lint.path: must not be empty"])
    }

    @Test func argumentsXcdSetsItselfAreRefused() {
        #expect(issues("  tool: swiftlint\n  args: [\"--strict\", \"--reporter\", \"xcode\", \"--no-cache\", \"--baseline=old.json\"]")
                == ["lint.args: xcd sets these itself, so they can't be given: --reporter, --no-cache, --baseline"])
        #expect(issues("  tool: swiftlint\n  args: [\"--strict\", \"--config\", \"ci/.swiftlint.yml\", \"--lenient\"]").isEmpty)
    }

    @Test func anUnknownToolIsRefused() {
        #expect(issues("  tool: swiftformat") == ["lint.tool: must be one of: swiftlint, none"])
    }

    @Test func theLocalFileSetsAPathForThisMac() throws {
        let config = try ConfigLoader.parse(main: Self.config("  tool: swiftlint"), local: "lint:\n  path: /opt/tools/swiftlint\n")
        #expect(config.lintSetup == .swiftlint(path: "/opt/tools/swiftlint", args: []))
    }

    @Test func lintAndFormatAreSections() {
        #expect(!ConfigSchema.reservedTopLevelKeys.contains("lint") && !ConfigSchema.reservedTopLevelKeys.contains("format"))
        #expect(BuiltinCommands.sectionNames == ["lint", "format"])
    }

    @Test func aProjectCommandNamedLikeASectionIsSentToTheSection() {
        let commands = "  lint: { run: ./scripts/lint.sh }\n  build: { run: make }\n  format: { run: ./scripts/format.sh }"
        #expect(Self.issues(commands, section: "commands") == [
            "commands.build: 'build' is a built-in xcd command, so `xcd build` would never run this; rename it",
            "commands.format: 'format' is a built-in xcd command; move this script to `format: { run: … }`",
            "commands.lint: 'lint' is a built-in xcd command; move this script to `lint: { run: … }`",
        ])
    }

    @Test func configExplainDescribesTheKeys() throws {
        #expect(try ConfigExplainReport(key: "lint.tool").text == """
        lint.tool (string)
        The linter `xcd lint` runs: swiftlint, or none for a project that has no linter.
        allowed: swiftlint, none
        example:
          lint:
            tool: swiftlint
        """)
        #expect(try ConfigExplainReport(key: "lint.run").text == """
        lint.run (string)
        The project's own lint command, in place of tool. A shell command run from the worktree root with the XCD_* context variables. The Swift files in scope are its arguments, and it names "$@" where they go: xcd adds nothing to the command, so one with no "$@" gets no files. Exit 0 means it passed.
        example:
          lint:
            run: ./scripts/lint.sh "$@"
        """)
        #expect(try ConfigExplainReport(key: "lint").text.hasSuffix("keys: lint.tool, lint.path, lint.args, lint.run"))
        #expect(try ConfigExplainer.explain("lint.args").type == "list of strings")
    }

    @Test func theNewErrorCodesHaveTheirExitCodes() {
        #expect(ErrorCode.lintFailed.rawValue == "lint_failed" && ErrorCode.lintFailed.exitCode == 1)
        #expect(ErrorCode.notConfigured.rawValue == "not_configured" && ErrorCode.notConfigured.exitCode == 2)
        #expect(ErrorCode.toolMissing.rawValue == "tool_missing" && ErrorCode.toolMissing.exitCode == 3)
    }
}
