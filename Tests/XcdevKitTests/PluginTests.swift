import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct PluginTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("xcd plugins \(UUID().uuidString)").path

    /// What the slow plugin leaves when it gets to finish.
    var finished: String { base + "/slow plugin finished" }

    func write(_ script: String, to path: String, executable: Bool = true) throws {
        let full = base + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + script + "\n").write(toFile: full, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: full)
    }

    func makePlugins() throws -> PluginFinder {
        try write(#"[ "$1" = --xcd-describe ] && echo "Lint the project" && exit 0; echo linting"#, to: "first/xcd-lint")
        try write(#"echo "second copy""#, to: "second/xcd-lint")
        try write("exit 1", to: "second/xcd-silent")
        // Its work runs as a job of its own, so it would still finish and leave the file if only the script were stopped.
        try write("(sleep 30; touch '\(finished)') & wait", to: "second/xcd-slow")
        try write("echo hi", to: "second/xcd-notexec", executable: false)
        try FileManager.default.createDirectory(atPath: base + "/second/xcd-dir", withIntermediateDirectories: true)
        try write("echo no", to: "second/xcd-")
        return PluginFinder(environment: ["PATH": "\(base)/first:\(base)/missing:\(base)/second"])
    }

    @Test func findsExecutablesOnPathFirstMatchWins() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let finder = try makePlugins()
        #expect(finder.plugins().map(\.name) == ["lint", "silent", "slow"])
        #expect(finder.plugin(named: "lint")?.path == base + "/first/xcd-lint")
        #expect(finder.plugin(named: "notexec") == nil)
    }

    /// No clock: in a full run the plugins start seconds late, behind the suite's other tests, so a bound on the time
    /// `describe` takes fails on a busy Mac. That the slow plugin never finished shows it was stopped, not waited for.
    @Test func describeAsksEachPluginWithATimeout() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let finder = try makePlugins()
        let runner = PluginRunner(runner: SystemProcessRunner(), describeTimeout: .milliseconds(500))
        let descriptions = await runner.describe(finder.plugins())
        #expect(descriptions == ["lint": "Lint the project"])
        #expect(!FileManager.default.fileExists(atPath: finished), "the slow plugin ran to its end")
    }

    @Test func runPassesArgumentsContextAndExitCode() async throws {
        let fake = FakeProcessRunner()
        fake.stub(["xcd-lint"], exitCode: 4)
        let plugin = Plugin(name: "lint", path: "/opt/bin/xcd-lint")
        let code = try await PluginRunner(runner: fake).run(plugin, arguments: ["--fix", "a b"],
                                                              environment: ["XCD_OUTPUT": "text"], workingDirectory: "/w")
        #expect(code == 4)
        let call = try #require(fake.calls.first)
        #expect(call.arguments == ["--fix", "a b"] && call.passthrough && call.workingDirectory == "/w")
        #expect(call.environment == ["XCD_OUTPUT": "text"] && call.timeout == .seconds(1800))
    }

    @Test func aTimeoutSaysThePluginRanTooLongWithoutSuggestingTimeout() async throws {
        let fake = FakeProcessRunner()
        fake.stub(["xcd-lint"]) { _ in
            throw XcdError(.timeout, "`/opt/bin/xcd-lint` timed out after 1800 seconds", next: "re-run with a larger --timeout")
        }
        let plugin = Plugin(name: "lint", path: "/opt/bin/xcd-lint")
        let error = await #expect(throws: XcdError.self) {
            try await PluginRunner(runner: fake).run(plugin, arguments: [], environment: [:], workingDirectory: "/w")
        }
        #expect(error?.code == .timeout)
        #expect(error?.message == "`xcd lint` ran longer than 30m00s and was stopped")
        #expect(error?.next == "xcd stops a plugin after 30m00s; its options, such as how to make it finish sooner, are in its own documentation (/opt/bin/xcd-lint)")
        #expect(error?.next?.contains("--timeout") == false)
    }
}
