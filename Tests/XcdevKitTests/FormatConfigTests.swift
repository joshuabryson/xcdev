import Foundation
import Testing
@testable import XcdevKit

/// The `format:` section.
@Suite struct FormatConfigTests {
    func parse(_ lines: String, local: String? = nil) throws -> XcdevConfig {
        try ConfigLoader.parse(main: QualityConfigTests.config(lines, section: "format"), local: local)
    }

    func issues(_ lines: String) -> [String] { QualityConfigTests.issues(lines, section: "format") }

    @Test func eachFormatterLoadsWithItsPathAndArguments() throws {
        let nick = try parse("  tool: swiftformat\n  path: tools/swiftformat\n  args: [\"--config\", \"ci/.swiftformat\"]")
        #expect(nick.format == FormatConfig(tool: .swiftFormat, path: "tools/swiftformat", args: ["--config", "ci/.swiftformat"]))
        #expect(nick.formatSetup == .tool(.swiftFormat, path: "tools/swiftformat", args: ["--config", "ci/.swiftformat"]))
        #expect(try parse("  tool: swift-format").formatSetup == .tool(.appleSwiftFormat, path: nil, args: []))
        #expect(FormatterKind.swiftFormat.configFile == ".swiftformat" && FormatterKind.appleSwiftFormat.configFile == ".swift-format")
    }

    @Test func aProjectsOwnCommandLoadsWithOrWithoutACheck() throws {
        #expect(try parse("  run: ./scripts/format.sh \"$@\"").formatSetup == .command(run: "./scripts/format.sh \"$@\"", check: nil))
        let both = try parse("  run: ./scripts/format.sh \"$@\"\n  check: ./scripts/format.sh --dry \"$@\"")
        #expect(both.formatSetup == .command(run: "./scripts/format.sh \"$@\"", check: "./scripts/format.sh --dry \"$@\""))
    }

    @Test func theSectionHasThreeStates() throws {
        #expect(try ConfigLoader.parse(main: "version: 1\nproject: App.xcodeproj\n").formatSetup == .absent)
        #expect(try parse("  tool: none").formatSetup == .off)
        #expect(try parse("  tool: swiftformat").formatSetup == .tool(.swiftFormat, path: nil, args: []))
    }

    @Test func aSectionHasExactlyOneOfToolAndRun() {
        #expect(issues("  tool: swiftformat\n  run: ./format.sh") == ["format: has tool and run; a section has exactly one of them"])
        #expect(issues("  {}") == ["format: needs one of tool or run"])
        #expect(issues("  check: ./format.sh --dry") == ["format: needs one of tool or run", "format.check: is only read with run"])
    }

    @Test func pathAndArgsGoWithAToolThatRunsAndCheckWithRun() {
        #expect(issues("  tool: none\n  path: tools/swiftformat") == ["format.path: is only read with a tool other than none"])
        #expect(issues("  run: ./format.sh\n  args: [\"-x\"]") == ["format.args: is only read with a tool other than none"])
        #expect(issues("  tool: swift-format\n  check: ./format.sh --dry") == ["format.check: is only read with run"])
    }

    @Test func anEmptyRunCheckOrPathIsRefused() {
        #expect(issues("  run: \"  \"") == ["format.run: must not be empty"])
        #expect(issues("  run: ./format.sh\n  check: \"\"") == ["format.check: must not be empty"])
        #expect(issues("  tool: swiftformat\n  path: \"\"") == ["format.path: must not be empty"])
    }

    @Test func argumentsXcdSetsItselfAreRefusedPerFormatter() {
        #expect(issues("  tool: swift-format\n  args: [\"--configuration\", \"ci/format.json\", \"--lines\", \"1:2\", \"-i\", \"--parallel\"]")
                == ["format.args: xcd sets these itself, so they can't be given: --lines, -i, --parallel"])
        #expect(issues("  tool: swiftformat\n  args: [\"--line-range\", \"1,2\", \"--linerange\", \"1,2\", \"--stdinpath\", \"a\", \"--lint\", \"--cache=clear\"]")
                == ["format.args: xcd sets these itself, so they can't be given: --line-range, --linerange, --stdinpath, --lint, --cache"])
        // One formatter's own arguments mean nothing to the other, so they are not looked for there.
        #expect(issues("  tool: swiftformat\n  args: [\"--lines\", \"-i\"]").isEmpty)
        #expect(issues("  tool: swiftformat\n  args: [\"--config\", \"ci/.swiftformat\", \"--swiftversion\", \"6.0\"]").isEmpty)
    }

    /// With these a formatter exits 0 and prints its version, its help, or a list, which xcd would write over
    /// every file in scope. `--strict` makes SwiftFormat fail on each file it reformats.
    @Test func argumentsThatMakeAFormatterPrintSomethingElseAreRefused() {
        let why = "format.args: these make the tool give xcd something other than the formatted file, so they can't be given: "
        #expect(issues("  tool: swift-format\n  args: [\"--version\", \"-h\", \"--help\"]") == [why + "--version, -h, --help"])
        #expect(issues("  tool: swiftformat\n  args: [\"--help\", \"--version\", \"--options\", \"--rules\", \"--ruleinfo\", \"indent\"]")
                == [why + "--help, --version, --options, --rules, --ruleinfo"])
        #expect(issues("  tool: swiftformat\n  args: [\"--rule-info\", \"--inferoptions\", \"--infer-options\", \"--strict\"]")
                == [why + "--rule-info, --inferoptions, --infer-options, --strict"])
        #expect(issues("  tool: swiftformat\n  args: [\"--quiet\", \"--version\"]") == [
            "format.args: xcd sets these itself, so they can't be given: --quiet", why + "--version",
        ])
    }

    @Test func anUnknownToolIsRefused() {
        #expect(issues("  tool: swiftlint") == ["format.tool: must be one of: swift-format, swiftformat, none"])
    }

    @Test func theLocalFileSetsAPathForThisMac() throws {
        let config = try parse("  tool: swiftformat", local: "format:\n  path: /opt/tools/swiftformat\n")
        #expect(config.formatSetup == .tool(.swiftFormat, path: "/opt/tools/swiftformat", args: []))
    }

    @Test func configExplainDescribesTheKeys() throws {
        #expect(try ConfigExplainReport(key: "format.tool").text == """
        format.tool (string)
        The formatter `xcd format` runs: swift-format (Apple's, which ships inside Xcode), swiftformat (Nick Lockwood's SwiftFormat), or none for a project that has no formatter.
        allowed: swift-format, swiftformat, none
        example:
          format:
            tool: swiftformat
        """)
        #expect(try ConfigExplainReport(key: "format.check").text == """
        format.check (string)
        What `xcd format --check` runs: a command that reports what it would change and rewrites nothing. It gets the files the way run does. Exit 0 means nothing needs formatting. Only with run.
        example:
          format:
            run: ./scripts/format.sh "$@"
            check: ./scripts/format.sh --dry "$@"
        """)
        #expect(try ConfigExplainReport(key: "format").text.hasSuffix("keys: format.tool, format.path, format.args, format.run, format.check"))
        #expect(try ConfigExplainReport(key: "format.run").text.contains(#"names "$@" where they go"#))
    }

    @Test func formatFailedIsATaskFailure() {
        #expect(ErrorCode.formatFailed.rawValue == "format_failed" && ErrorCode.formatFailed.exitCode == 1)
        #expect(ErrorCode.toolMissing.summary.contains("linter or formatter"))
    }
}
