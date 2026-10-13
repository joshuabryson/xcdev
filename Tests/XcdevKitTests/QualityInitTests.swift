import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The `lint.tool` decision of `xcd init` and the section it writes. These tests share the
/// recorded project of `InitServiceTests`.
extension InitServiceTests {
    /// A locator that finds a `swiftlint` it can run, which answers `version` with 0.63.3.
    func installedSwiftLint(_ project: TempProject) throws -> ToolLocator {
        try project.write("#!/bin/sh\n", to: "bin/swiftlint", in: project.base)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.base + "/bin/swiftlint")
        fake.stub(["swiftlint", "version"], stdout: "0.63.3\n")
        return ToolLocator(environment: ["PATH": project.base + "/bin"], extraFolders: [])
    }

    func lintDecision(_ service: InitService, _ project: TempProject) async throws -> InitDecision {
        try #require(try await service.plan(from: project.root).decisions.last)
    }

    @Test func aProjectWithASwiftLintConfigIsAskedWhetherToUseIt() async throws {
        var (project, service) = try setup()
        defer { project.remove() }
        try project.write("included:\n  - App\n", to: ".swiftlint.yml")
        service.locator = try installedSwiftLint(project)
        let decision = try await lintDecision(service, project)
        #expect(decision == InitDecision(
            key: "lint.tool",
            ask: "This project has a .swiftlint.yml. Should `xcd lint` run SwiftLint? SwiftLint 0.63.3 is installed on this Mac.",
            options: ["swiftlint", "none"], recommended: "swiftlint", reason: "the project has a .swiftlint.yml"))
    }

    /// Nothing is chosen for the project: with no tool config the recommendation is `none`.
    @Test func aProjectWithNoLinterIsOfferedOneAndNoneIsRecommended() async throws {
        let (project, service) = try setup()
        defer { project.remove() }
        let decision = try await lintDecision(service, project)
        #expect(decision.options == ["none", "swiftlint"] && decision.recommended == "none")
        #expect(decision.reason == "the project has no .swiftlint.yml")
        #expect(decision.ask == "No linter is set up in this project. Should `xcd lint` run SwiftLint? It would use SwiftLint's default "
                + "rules until the project adds a .swiftlint.yml. SwiftLint is not installed on this Mac; `brew install swiftlint` installs it.")
        let text = try await service.plan(from: project.root).text
        #expect(text.contains("\ndecision lint.tool\n  ask: \"No linter is set up in this project."))
        #expect(text.contains("\n  options: none (recommended: the project has no .swiftlint.yml), swiftlint\n"))
    }

    @Test func aSwiftLintThatDoesNotSayItsVersionIsStillInstalled() async throws {
        var (project, service) = try setup()
        defer { project.remove() }
        service.locator = try installedSwiftLint(project)
        fake.stub(["swiftlint", "version"], exitCode: 1)
        #expect(try await lintDecision(service, project).ask.hasSuffix("SwiftLint is installed on this Mac."))
    }

    @Test func theDefaultsAlwaysWriteTheSection() async throws {
        let (project, service) = try setup()
        defer { project.remove() }
        let none = try await service.write(answers: [:], force: false, from: project.root)
        #expect(try String(contentsOfFile: project.root + "/.xcdev.yml", encoding: .utf8).hasSuffix("\nlint:\n  tool: none\n"))
        #expect(try ConfigLoader.load(worktreeRoot: project.root, projectRoot: project.root).lintSetup == .off)
        #expect(none.summary.last == "lint: none")

        try project.write("included:\n  - App\n", to: ".swiftlint.yml")
        let found = try await service.write(answers: [:], force: true, from: project.root)
        #expect(try ConfigLoader.load(worktreeRoot: project.root, projectRoot: project.root).lintSetup == .swiftlint(path: nil, args: []))
        #expect(found.summary.last == "lint: swiftlint")
        #expect(found.text.contains("\nlint: swiftlint\n"))
    }

    @Test func anAnswerChoosesTheLinterAndABadOneIsRefused() async throws {
        let (project, service) = try setup()
        defer { project.remove() }
        _ = try await service.write(answers: ["lint.tool": "SwiftLint", "devices.watch": "none"], force: false, from: project.root)
        let config = try ConfigLoader.load(worktreeRoot: project.root, projectRoot: project.root)
        #expect(config.lintSetup == .swiftlint(path: nil, args: []) && config.allDevices["watch"] == nil)

        let error = await #expect(throws: XcdError.self) {
            try await service.write(answers: ["lint.tool": "swiftformat"], force: true, from: project.root)
        }
        #expect(error?.code == .configInvalid && error?.message == "'swiftformat' is not an option for lint.tool")
        #expect(error?.next == "use one of: none, swiftlint")
        #expect(try ConfigLoader.load(worktreeRoot: project.root, projectRoot: project.root) == config)       // nothing was written
    }

    /// `init` changes nothing in a project that has a config. One from before the section existed gets a warning
    /// that says what to add.
    @Test func initOnAConfigWithoutTheSectionSaysHowToAddIt() async throws {
        let (project, service) = try setup()
        defer { project.remove() }
        try project.write("version: 1\nproject: SampleApp.xcodeproj\n", to: ".xcdev.yml")
        let report = try await service.write(answers: [:], force: false, from: project.root)
        #expect(report.status == .unchanged)
        #expect(report.warnings == ["`xcd lint` is not set up: add `lint: { tool: swiftlint }` to .xcdev.yml, or "
                                    + "`lint: { tool: none }` if the project has no linter"])

        try project.write("included:\n  - App\n", to: ".swiftlint.yml")
        #expect(try await service.write(answers: [:], force: false, from: project.root).warnings
                == ["`xcd lint` is not set up: .swiftlint.yml found: run `xcd doctor --fix`, or add `lint: { tool: swiftlint }` to .xcdev.yml"])

        try project.write("version: 1\nproject: SampleApp.xcodeproj\nlint:\n  tool: none\n", to: ".xcdev.yml")
        #expect(try await service.write(answers: [:], force: false, from: project.root).warnings.isEmpty)
    }
}
