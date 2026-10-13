import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Running Apple's swift-format on one file and reading what it gives. The formatter is a stub.
@Suite struct AppleSwiftFormatToolTests {
    static let executable = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-format"
    let runner = FakeProcessRunner()

    func tool(args: [String] = []) -> AppleSwiftFormatTool {
        AppleSwiftFormatTool(runner: runner, executable: Self.executable, args: args, worktreeRoot: "/work/My App")
    }

    func job(_ ranges: [LineRange]? = nil, text: String = "let a=1\n") -> FormatJob {
        FormatJob(path: "Sources/App/A.swift", text: text, ranges: ranges)
    }

    @Test func aWholeFileIsAskedForByItsFullPathWithNoRange() async throws {
        runner.stub(["swift-format"], stdout: "let a = 1\n")
        let answer = try await tool(args: ["--configuration", "ci/format.json"]).format(job())
        #expect(answer.text == "let a = 1\n" && answer.said.isEmpty)
        let call = try #require(runner.calls.first)
        #expect(call.executable == Self.executable)
        #expect(call.arguments == ["format", "--configuration", "ci/format.json", "/work/My App/Sources/App/A.swift"])
        #expect(call.workingDirectory == "/work/My App" && call.timeout == .seconds(120) && call.inputFile == nil)
        #expect(answer.transcript == "$ swift-format format --configuration ci/format.json '/work/My App/Sources/App/A.swift'\nexit 0\n")
    }

    @Test func everyRangeGoesIntoTheOneCall() async throws {
        runner.stub(["swift-format"], stdout: "let a = 1\n")
        _ = try await tool(args: ["--configuration", "ci/format.json"]).format(job([LineRange(3, 5), LineRange(9, 9)]))
        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.arguments
                == ["format", "--lines", "3:5", "--lines", "9:9", "--configuration", "ci/format.json", "/work/My App/Sources/App/A.swift"])
    }

    /// No ranges is not "no range": without `--lines` swift-format would format the whole file.
    @Test func noRangesAtAllRunsNothing() async throws {
        let answer = try await tool().format(job([]))
        #expect(answer.text == "let a=1\n" && runner.calls.isEmpty)
    }

    /// A file that does not parse: exit 1, nothing on stdout, and the reason on stderr with the file's full path.
    @Test func aFailedRunGivesNoTextAndTheFormattersOwnLines() async throws {
        let said = "/work/My App/Sources/App/A.swift:2:10: error: expected ')' to end parameter clause\n\n/work/My App/Sources/App/A.swift:3:2: error: expected '}' to end struct\n"
        runner.stub(["swift-format"], exitCode: 1, stdout: "let a=1\n", stderr: said)
        let answer = try await tool().format(job())
        #expect(answer.text == nil)
        #expect(answer.said == ["/work/My App/Sources/App/A.swift:2:10: error: expected ')' to end parameter clause",
                                "/work/My App/Sources/App/A.swift:3:2: error: expected '}' to end struct"])
        #expect(answer.transcript.contains("\nexit 1\n/work/My App/Sources/App/A.swift:2:10: error:"))
        runner.stub(["swift-format"], exitCode: 64)
        #expect(try await tool().format(job()).said == ["exited with code 64 and said nothing"])
    }

    @Test func whatAFormatterSaysWhileItWorksIsKept() async throws {
        runner.stub(["swift-format"], stdout: "let a = 1\n", stderr: "<unknown>: warning: Configuration contains an unrecognized rule: NoSuchRule\n")
        let answer = try await tool().format(job())
        #expect(answer.text == "let a = 1\n" && answer.said == ["<unknown>: warning: Configuration contains an unrecognized rule: NoSuchRule"])
    }

    /// swift-format exits 0 and prints nothing for a file its `.swift-format-ignore` names. That is not an empty file.
    @Test func aFormatterThatPrintsNothingLeftTheFileOut() async throws {
        runner.stub(["swift-format"], stdout: "")
        #expect(try await tool().format(job()).text == "let a=1\n")
        #expect(try await tool().format(job(text: "")).text == "")
    }

    @Test func aRunPastItsDeadlineIsAFileThatCouldNotBeProcessed() async throws {
        runner.stub(["swift-format"]) { _ in throw XcdError(.timeout, "`swift-format format` timed out after 2m") }
        let answer = try await tool().format(job())
        #expect(answer.text == nil && answer.said == ["did not finish in 2m00s and was stopped"])
        #expect(answer.transcript.hasSuffix("\nstopped after 2m00s\n"))
    }

    @Test func outputThatIsNotTextIsNotUsed() async throws {
        runner.stub(["swift-format"]) { _ in ProcessOutput(exitCode: 0, stdoutData: Data([0x6C, 0x65, 0x74, 0xE9, 0x0A]), stderrData: Data()) }
        let answer = try await tool().format(job())
        #expect(answer.text == nil && answer.said == ["printed text that is not UTF-8"])
    }

    @Test func aFormatterThatCannotBeStartedEndsTheCommand() async {
        runner.stub(["swift-format"]) { _ in throw XcdError(.subprocessFailed, "could not launch swift-format") }
        let error = await #expect(throws: XcdError.self) { _ = try await tool().format(job()) }
        #expect(error?.code == .subprocessFailed)
    }
}
