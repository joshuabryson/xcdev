import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd doctor` on the `format:` section: a project that has a formatter's config file and never
/// said whether `xcd format` should use it, and a formatter the config names that is not on this Mac.
@Suite struct FormatChecksTests {
    static let base = QualityChecksTests.base
    static let problem = ".xcdev.yml has no `format:` section, and the project has a .swiftformat, so `xcd format` is not set up"
    static let done = "added `format: { tool: swiftformat }` to .xcdev.yml; the change is yours to commit"
    static let fix = "add `format: { tool: swiftformat }` to .xcdev.yml; the change is then yours to commit"

    /// The project, the doctor, and the locator of `QualityChecksTests`.
    let quality = QualityChecksTests()

    @Test func aFormatterConfigNobodyDecidedAboutIsAProblemWithAFix() async throws {
        let project = try quality.setup()
        defer { project.remove() }
        try project.write("--indent 4\n", to: ".swiftformat")

        let report = await quality.doctor(project).run(fix: false, checks: [QualitySetupCheck()], from: project.root)
        #expect(report.problems == [DoctorProblem(check: "quality-setup", message: Self.problem, action: .addFormatSection, fix: Self.fix,
                                                  subject: project.root + "/.xcdev.yml", done: Self.done)])
        #expect(report.text.contains("problem  quality-setup  \(Self.problem)  (--fix: \(Self.fix))"))
        #expect(try quality.config(project) == Self.base)                        // reported only, without --fix

        let fixed = await quality.doctor(project).run(fix: true, checks: [QualitySetupCheck()], from: project.root)
        #expect(fixed.problems.map(\.fixed) == [true] && fixed.failure == nil)
        #expect(fixed.text.contains("fixed    quality-setup  \(Self.problem)  (\(Self.done))"))
        #expect(try quality.config(project) == Self.base + "format:\n  tool: swiftformat\n")
        #expect(try ConfigLoader.load(worktreeRoot: project.root, projectRoot: project.root).formatSetup == .tool(.swiftFormat, path: nil, args: []))
        #expect(await quality.doctor(project).run(fix: false, checks: [QualitySetupCheck()], from: project.root).problems.isEmpty)
    }

    @Test func theFixNamesTheFormatterWhoseFileTheProjectHas() async throws {
        let project = try quality.setup()
        defer { project.remove() }
        try project.write("{}\n", to: ".swift-format")
        let fixed = await quality.doctor(project).run(fix: true, checks: [QualitySetupCheck()], from: project.root)
        #expect(fixed.problems.first?.message == ".xcdev.yml has no `format:` section, and the project has a .swift-format, so `xcd format` is not set up")
        #expect(fixed.problems.first?.done == "added `format: { tool: swift-format }` to .xcdev.yml; the change is yours to commit")
        #expect(try quality.config(project) == Self.base + "format:\n  tool: swift-format\n")
    }

    /// With both files nothing says which formatter the project uses. Doctor reports it and chooses nothing.
    @Test func bothFormatterConfigsAreAProblemWithNoFix() async throws {
        let project = try quality.setup()
        defer { project.remove() }
        try project.write("--indent 4\n", to: ".swiftformat")
        try project.write("{}\n", to: ".swift-format")
        let report = await quality.doctor(project).run(fix: true, checks: [QualitySetupCheck()], from: project.root)
        #expect(report.problems == [DoctorProblem(
            check: "quality-setup",
            message: ".xcdev.yml has no `format:` section, and the project has a .swift-format and .swiftformat, so `xcd format` is not set up",
            next: "add `format: { tool: swift-format }` or `format: { tool: swiftformat }` to .xcdev.yml, whichever the project uses",
            subject: project.root + "/.xcdev.yml")])
        #expect(report.failure?.code == .doctorProblems)
        #expect(try quality.config(project) == Self.base)
    }

    /// A project from before both sections, with both tools' files: one problem each, and one run fixes both.
    @Test func aLinterAndAFormatterAreSetUpInOneRun() async throws {
        let project = try quality.setup()
        defer { project.remove() }
        try project.write("included:\n  - App\n", to: ".swiftlint.yml")
        try project.write("--indent 4\n", to: ".swiftformat")
        let fixed = await quality.doctor(project).run(fix: true, checks: [QualitySetupCheck()], from: project.root)
        #expect(fixed.problems.map(\.action) == [.addLintSection, .addFormatSection] && fixed.problems.allSatisfy(\.fixed))
        #expect(try quality.config(project) == Self.base + "lint:\n  tool: swiftlint\nformat:\n  tool: swiftformat\n")
    }

    /// No config file is nothing to set up, and a project that said `none` made its choice: neither is a problem,
    /// with or without `--fix`, or doctor would fail for good there.
    @Test func noFormatterConfigAndAProjectThatSaidNoneAreLeftAlone() async throws {
        for (config, file) in [(Self.base, nil), (Self.base + "format:\n  tool: none\n", ".swiftformat"), (Self.base + "format:\n  run: ./format.sh\n", ".swiftformat")] {
            let project = try quality.setup(config)
            defer { project.remove() }
            if let file { try project.write("--indent 4\n", to: file) }
            for fix in [false, true] {
                let report = await quality.doctor(project).run(fix: fix, checks: [QualitySetupCheck(), QualityToolsCheck()], from: project.root)
                #expect(report.problems.isEmpty && report.failure == nil, "\(config)")
            }
            #expect(try quality.config(project) == config)
        }
    }

    /// The fix reads the file, and which formatter's config is there, as they are when it runs.
    @Test func theFormatFixLooksAgainBeforeItWrites() async throws {
        let project = try quality.setup()
        defer { project.remove() }
        try project.write("--indent 4\n", to: ".swiftformat")
        let env = await quality.doctor(project).environment(from: project.root)
        let problem = try #require(QualitySetupCheck().detect(env).first)

        try project.write("{}\n", to: ".swift-format")                          // a second formatter's file came meanwhile
        #expect(throws: DoctorLeftAlone(note: "the project no longer has exactly one formatter's config file; left alone")) {
            try QualitySetupCheck().fix(problem, env)
        }
        try FileManager.default.removeItem(atPath: project.root + "/.swift-format")
        try project.write(Self.base + "format:\n  tool: none\n", to: ".xcdev.yml")       // someone decided meanwhile
        #expect(throws: DoctorLeftAlone(note: ".xcdev.yml has a `format:` section now; left alone")) {
            try QualitySetupCheck().fix(problem, env)
        }
        #expect(try quality.config(project) == Self.base + "format:\n  tool: none\n")
    }

    @Test func aFileTheFormatFixCannotExtendIsLeftAsItWas() async throws {
        let flow = "{version: 1, project: App.xcodeproj}\n"
        let project = try quality.setup(flow)
        defer { project.remove() }
        try project.write("--indent 4\n", to: ".swiftformat")
        let report = await quality.doctor(project).run(fix: true, checks: [QualitySetupCheck()], from: project.root)
        #expect(report.problems.first?.fixError
                == "doctor can't add the section to this .xcdev.yml; add `format: { tool: swiftformat }` to .xcdev.yml by hand")
        #expect(try quality.config(project) == flow)
    }

    @Test func aFormatterThatIsNotInstalledIsAProblemThatSaysHowToGetIt() async throws {
        let project = try quality.setup(Self.base + "format:\n  tool: swiftformat\n")
        defer { project.remove() }
        let missing = QualityToolsCheck(locator: try quality.locator(project, installed: false))
        let report = await quality.doctor(project).run(fix: true, checks: [missing], from: project.root)
        #expect(report.problems == [DoctorProblem(check: "quality-tools",
                                                  message: "swiftformat is not installed: it is not in PATH, /opt/homebrew/bin, or /usr/local/bin",
                                                  next: "brew install swiftformat, or set format.path in .xcdev.local.yml")])
        try project.write("#!/bin/sh\n", to: "bin/swiftformat", in: project.base)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.base + "/bin/swiftformat")
        #expect(await quality.doctor(project).run(fix: false, checks: [missing], from: project.root).problems.isEmpty)
    }

    /// Apple's swift-format is asked of Xcode, as `xcd format` asks. One in PATH is not what would run.
    @Test func applesFormatterIsLookedForInXcode() async throws {
        let project = try quality.setup(Self.base + "format:\n  tool: swift-format\n")
        defer { project.remove() }
        try project.write("#!/bin/sh\n", to: "bin/swift-format", in: project.base)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.base + "/bin/swift-format")
        let check = QualityToolsCheck(locator: try quality.locator(project, installed: false))
        quality.shared.fake.stub(["xcrun", "--find", "swift-format"], exitCode: 72)
        let report = await quality.doctor(project).run(fix: false, checks: [check], from: project.root)
        #expect(report.problems.map(\.message) == ["the selected Xcode has no swift-format"])
        #expect(report.problems.first?.next == "set format.tool to swiftformat or none in .xcdev.yml, or set format.path in .xcdev.local.yml to a swift-format outside Xcode")
        quality.shared.fake.stub(["xcrun", "--find", "swift-format"], stdout: project.base + "/bin/swift-format\n")
        #expect(await quality.doctor(project).run(fix: false, checks: [check], from: project.root).problems.isEmpty)
    }

    /// A linter and a formatter that are both missing are two problems of the one check.
    @Test func eachMissingToolIsItsOwnProblem() async throws {
        let project = try quality.setup(Self.base + "lint:\n  tool: swiftlint\nformat:\n  tool: swiftformat\n  path: tools/swiftformat\n")
        defer { project.remove() }
        let check = QualityToolsCheck(locator: try quality.locator(project, installed: false))
        let report = await quality.doctor(project).run(fix: false, checks: [check], from: project.root)
        #expect(report.problems.map(\.message) == ["swiftlint is not installed: it is not in PATH, /opt/homebrew/bin, or /usr/local/bin",
                                                   "format.path names 'tools/swiftformat', which is not a file that can be run"])
    }
}
