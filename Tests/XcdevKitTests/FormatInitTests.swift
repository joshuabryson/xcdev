import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The `format.tool` decision of `xcd init` and the section it writes. These tests share the
/// recorded project of `InitServiceTests`.
extension InitServiceTests {
    /// A locator that finds a `swiftformat` it can run, which answers `--version` with 0.61.1.
    func installedSwiftFormat(_ project: TempProject) throws -> ToolLocator {
        try project.write("#!/bin/sh\n", to: "bin/swiftformat", in: project.base)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.base + "/bin/swiftformat")
        fake.stub(["swiftformat", "--version"], stdout: "0.61.1\n")
        return ToolLocator(environment: ["PATH": project.base + "/bin"], extraFolders: [])
    }

    /// Has `xcrun --find swift-format` name a file that can be run, as an Xcode that ships the formatter does.
    func xcodeWithSwiftFormat(_ project: TempProject) throws {
        try project.write("#!/bin/sh\n", to: "xcode/swift-format", in: project.base)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.base + "/xcode/swift-format")
        fake.stub(["xcrun", "--find", "swift-format"], stdout: project.base + "/xcode/swift-format\n")
    }

    /// Nothing is chosen for the project: with no formatter config the recommendation is `none`, and the question
    /// says what choosing either formatter would mean.
    @Test func aProjectWithNoFormatterIsOfferedBothAndNoneIsRecommended() async throws {
        var (project, service) = try setup()
        defer { project.remove() }
        service.locator = try installedSwiftFormat(project)
        try xcodeWithSwiftFormat(project)
        let decision = try await decision("format.tool", service, project)
        #expect(decision == InitDecision(
            key: "format.tool",
            ask: "No formatter is set up in this project. Do you want one? Xcode's swift-format needs no install and indents with 2 spaces "
                + "unless you add a .swift-format file. SwiftFormat 0.61.1 is installed on this Mac. It would use its default rules until the "
                + "project adds a .swiftformat file.",
            options: ["none", "swift-format", "swiftformat"], recommended: "none", reason: "the project has no formatter config"))
        let text = try await service.plan(from: project.root).text
        #expect(text.contains("\ndecision format.tool\n  ask: \"No formatter is set up in this project."))
        #expect(text.contains("\n  options: none (recommended: the project has no formatter config), swift-format, swiftformat\n"))
    }

    @Test func aProjectWithASwiftFormatConfigIsAskedWhetherToUseIt() async throws {
        let (project, service) = try setup()
        defer { project.remove() }
        try project.write("--indent 4\n", to: ".swiftformat")
        let decision = try await decision("format.tool", service, project)
        #expect(decision == InitDecision(
            key: "format.tool",
            ask: "This project has a .swiftformat. Should `xcd format` run SwiftFormat? SwiftFormat is not installed on this Mac; "
                + "`brew install swiftformat` installs it.",
            options: ["swiftformat", "none", "swift-format"], recommended: "swiftformat", reason: "the project has a .swiftformat"))
    }

    @Test func aProjectWithAnAppleFormatConfigIsAskedWhetherToUseXcodesFormatter() async throws {
        let (project, service) = try setup()
        defer { project.remove() }
        try project.write("{}\n", to: ".swift-format")
        let without = try await decision("format.tool", service, project)
        #expect(without.options == ["swift-format", "none", "swiftformat"] && without.recommended == "swift-format")
        #expect(without.reason == "the project has a .swift-format")
        #expect(without.ask == "This project has a .swift-format. Should `xcd format` run Xcode's swift-format? The selected Xcode has no swift-format.")
        try xcodeWithSwiftFormat(project)
        #expect(try await decision("format.tool", service, project).ask
                == "This project has a .swift-format. Should `xcd format` run Xcode's swift-format? Xcode's swift-format needs no install.")
    }

    /// With both files xcd cannot tell which formatter the project uses, so it recommends neither.
    @Test func aProjectWithBothConfigFilesIsAskedWhichAndNoneIsRecommended() async throws {
        var (project, service) = try setup()
        defer { project.remove() }
        try project.write("--indent 4\n", to: ".swiftformat")
        try project.write("{}\n", to: ".swift-format")
        service.locator = try installedSwiftFormat(project)
        try xcodeWithSwiftFormat(project)
        let decision = try await decision("format.tool", service, project)
        #expect(decision.options == ["none", "swiftformat", "swift-format"] && decision.recommended == "none")
        #expect(decision.reason == "the project has both files, so xcd can't tell which formatter it uses")
        #expect(decision.ask == "This project has a .swiftformat and a .swift-format. Which formatter should `xcd format` run? "
                + "SwiftFormat 0.61.1 is installed on this Mac. Xcode's swift-format needs no install.")
    }

    @Test func theDefaultsAlwaysWriteTheFormatSection() async throws {
        let (project, service) = try setup()
        defer { project.remove() }
        let none = try await service.write(answers: [:], force: false, from: project.root)
        #expect(try String(contentsOfFile: project.root + "/.xcdev.yml", encoding: .utf8).hasSuffix("\nlint:\n  tool: none\nformat:\n  tool: none\n"))
        #expect(try ConfigLoader.load(worktreeRoot: project.root, projectRoot: project.root).formatSetup == .off)
        #expect(none.summary.suffix(2) == ["lint: none", "format: none"])

        try project.write("--indent 4\n", to: ".swiftformat")
        let found = try await service.write(answers: [:], force: true, from: project.root)
        #expect(try ConfigLoader.load(worktreeRoot: project.root, projectRoot: project.root).formatSetup == .tool(.swiftFormat, path: nil, args: []))
        #expect(found.summary.last == "format: swiftformat" && found.text.contains("\nformat: swiftformat"))

        try project.write("{}\n", to: ".swift-format")                           // both files: nothing is chosen
        _ = try await service.write(answers: [:], force: true, from: project.root)
        #expect(try ConfigLoader.load(worktreeRoot: project.root, projectRoot: project.root).formatSetup == .off)
    }

    @Test func anAnswerChoosesTheFormatterAndABadOneIsRefused() async throws {
        let (project, service) = try setup()
        defer { project.remove() }
        _ = try await service.write(answers: ["format.tool": "Swift-Format", "lint.tool": "swiftlint"], force: false, from: project.root)
        let config = try ConfigLoader.load(worktreeRoot: project.root, projectRoot: project.root)
        #expect(config.formatSetup == .tool(.appleSwiftFormat, path: nil, args: []) && config.lintSetup == .swiftlint(path: nil, args: []))

        let error = await #expect(throws: XcdError.self) {
            try await service.write(answers: ["format.tool": "prettier"], force: true, from: project.root)
        }
        #expect(error?.code == .configInvalid && error?.message == "'prettier' is not an option for format.tool")
        #expect(error?.next == "use one of: none, swift-format, swiftformat")
        #expect(try ConfigLoader.load(worktreeRoot: project.root, projectRoot: project.root) == config)       // nothing was written
    }

    @Test func initOnAConfigWithoutTheFormatSectionSaysHowToAddIt() async throws {
        let (project, service) = try setup()
        defer { project.remove() }
        try project.write("version: 1\nproject: SampleApp.xcodeproj\nlint:\n  tool: none\n", to: ".xcdev.yml")
        let report = try await service.write(answers: [:], force: false, from: project.root)
        #expect(report.status == .unchanged)
        #expect(report.warnings == ["`xcd format` is not set up: add `format: { tool: swift-format }` to .xcdev.yml for Xcode's formatter, which "
                                    + "indents with 2 spaces unless the project adds a .swift-format file, or `format: { tool: none }` if the "
                                    + "project has no formatter"])
        try project.write("--indent 4\n", to: ".swiftformat")
        #expect(try await service.write(answers: [:], force: false, from: project.root).warnings
                == ["`xcd format` is not set up: .swiftformat found: run `xcd doctor --fix`, or add `format: { tool: swiftformat }` to .xcdev.yml"])
        // A config from before both sections gets both warnings, the linter's first.
        try project.write("version: 1\nproject: SampleApp.xcodeproj\n", to: ".xcdev.yml")
        let both = try await service.write(answers: [:], force: false, from: project.root).warnings
        #expect(both.count == 2 && both[0].hasPrefix("`xcd lint` is not set up: ") && both[1].hasPrefix("`xcd format` is not set up: "))
    }
}
