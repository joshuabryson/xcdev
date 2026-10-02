import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct PluginTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("xcd plugins \(UUID().uuidString)").path

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
        try write("sleep 10", to: "second/xcd-slow")
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

    @Test func describeAsksEachPluginWithATimeout() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let finder = try makePlugins()
        let runner = PluginRunner(runner: SystemProcessRunner(), describeTimeout: .milliseconds(500))
        let start = ContinuousClock.now
        let descriptions = await runner.describe(finder.plugins())
        #expect(descriptions == ["lint": "Lint the project"])
        #expect(ContinuousClock.now - start < .seconds(5))
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
}
