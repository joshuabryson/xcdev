import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd doctor` on the `lint:` section: a project that has a SwiftLint config and never said
/// whether `xcd lint` should use it, and a linter the config names that is not on this Mac.
@Suite struct QualityChecksTests {
    static let base = "version: 1\nproject: App.xcodeproj\n"
    static let problem = ".xcdev.yml has no `lint:` section, and the project has a .swiftlint.yml, so `xcd lint` is not set up"
    static let fix = "add `lint: { tool: swiftlint }` to .xcdev.yml; the change is then yours to commit"

    /// The doctor of `SwiftLintCheckTests`: simulators from the simctl-list fixture, and git run for real.
    let shared = SwiftLintCheckTests()

    /// A project whose .xcdev.yml is `config`.
    func setup(_ config: String = QualityChecksTests.base) throws -> TempProject {
        _ = try FakeSimulators(runner: shared.fake, catalogJSON: Fixture.string("simctl-list.json"))
        return try TempProject.make(config: config)
    }

    func doctor(_ project: TempProject) -> DoctorService { shared.doctor(project) }

    func config(_ project: TempProject) throws -> String {
        try String(contentsOfFile: project.root + "/.xcdev.yml", encoding: .utf8)
    }

    /// A locator that finds nothing, or a `swiftlint` in `<base>/bin` when `installed`.
    func locator(_ project: TempProject, installed: Bool) throws -> ToolLocator {
        if installed {
            try project.write("#!/bin/sh\n", to: "bin/swiftlint", in: project.base)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.base + "/bin/swiftlint")
        }
        return ToolLocator(environment: ["PATH": project.base + "/bin"], extraFolders: [])
    }

    @Test func aSwiftLintConfigNobodyDecidedAboutIsAProblemWithAFix() async throws {
        let project = try setup()
        defer { project.remove() }
        try project.write("included:\n  - App\n", to: ".swiftlint.yml")

        let report = await doctor(project).run(fix: false, from: project.root)
        #expect(report.checks.map(\.id).suffix(4) == ["quality-setup", "quality-tools", "project", "swiftlint"])
        #expect(report.problems.filter { $0.check == "quality-setup" } == [
            DoctorProblem(check: "quality-setup", message: Self.problem, action: .addLintSection, fix: Self.fix,
                          subject: project.root + "/.xcdev.yml")])
        #expect(report.text.contains("problem  quality-setup  \(Self.problem)  (--fix: \(Self.fix))"))
        #expect(try config(project) == Self.base)                               // reported only, without --fix

        let fixed = await doctor(project).run(fix: true, checks: [QualitySetupCheck()], from: project.root)
        #expect(fixed.problems.map(\.fixed) == [true] && fixed.failure == nil)
        #expect(try config(project) == Self.base + "lint:\n  tool: swiftlint\n")
        #expect(try ConfigLoader.load(worktreeRoot: project.root, projectRoot: project.root).lintSetup == .swiftlint(path: nil, args: []))
        let after = await doctor(project).run(fix: false, checks: [QualitySetupCheck()], from: project.root)
        #expect(after.problems.isEmpty && after.text.contains("ok       quality-setup"))
    }

    /// Every project from before this version has no section. With no tool config there is nothing to set up.
    @Test func noSectionAndNoSwiftLintConfigIsNoProblem() async throws {
        let project = try setup()
        defer { project.remove() }
        let report = await doctor(project).run(fix: true, checks: [QualitySetupCheck(), QualityToolsCheck()], from: project.root)
        #expect(report.checks.map(\.id) == ["quality-setup", "quality-tools"] && report.problems.isEmpty)
        #expect(try config(project) == Self.base)
    }

    /// Doctor cannot tell a config file added later from one the person declined at `init`, so it never turns
    /// `tool: none` into a tool. `xcd lint` itself points the file out.
    @Test func aProjectThatSaidNoneIsLeftAlone() async throws {
        let project = try setup(Self.base + "lint:\n  tool: none\n")
        defer { project.remove() }
        try project.write("included:\n  - App\n", to: ".swiftlint.yml")
        // Without --fix too: a problem here would fail doctor for good in a project that declined a linter.
        for fix in [false, true] {
            let report = await doctor(project).run(fix: fix, checks: [QualitySetupCheck(), QualityToolsCheck()], from: project.root)
            #expect(report.problems.isEmpty && report.failure == nil)
            #expect(report.text.contains("ok       quality-setup"))
        }
        #expect(try config(project) == Self.base + "lint:\n  tool: none\n")
    }

    @Test func theSectionIsAddedAfterWhateverTheFileEndsWith() async throws {
        let project = try setup("# ours\nversion: 1\nproject: App.xcodeproj   # the app")
        defer { project.remove() }
        try project.write("included:\n  - App\n", to: ".swiftlint.yml")
        _ = await doctor(project).run(fix: true, checks: [QualitySetupCheck()], from: project.root)
        #expect(try config(project) == "# ours\nversion: 1\nproject: App.xcodeproj   # the app\nlint:\n  tool: swiftlint\n")
    }

    /// A file written as one flow mapping can't take lines at its end: the result would not load, so nothing is written.
    @Test func aFileTheFixCannotExtendIsLeftAsItWas() async throws {
        let flow = "{version: 1, project: App.xcodeproj}\n"
        let project = try setup(flow)
        defer { project.remove() }
        try project.write("included:\n  - App\n", to: ".swiftlint.yml")
        let report = await doctor(project).run(fix: true, checks: [QualitySetupCheck()], from: project.root)
        #expect(report.problems.map(\.fixed) == [false])
        #expect(report.problems.first?.fixError
                == "doctor can't add the section to this .xcdev.yml; add `lint: { tool: swiftlint }` to .xcdev.yml by hand")
        #expect(try config(project) == flow)
        #expect(report.failure?.code == .doctorProblems)
    }

    /// The fix reads the file as it is when it runs, not as `detect` saw it.
    @Test func theFixLooksAgainBeforeItWrites() async throws {
        let project = try setup()
        defer { project.remove() }
        try project.write("included:\n  - App\n", to: ".swiftlint.yml")
        let service = doctor(project)
        let env = await service.environment(from: project.root)
        let problem = try #require(QualitySetupCheck().detect(env).first)
        try project.write(Self.base + "lint:\n  run: ./lint.sh\n", to: ".xcdev.yml")     // someone set it up meanwhile
        #expect(throws: DoctorLeftAlone(note: ".xcdev.yml has a `lint:` section now; left alone")) {
            try QualitySetupCheck().fix(problem, env)
        }
        #expect(try config(project) == Self.base + "lint:\n  run: ./lint.sh\n")
    }

    @Test func aLinterThatIsNotInstalledIsAProblemThatSaysHowToGetIt() async throws {
        let project = try setup(Self.base + "lint:\n  tool: swiftlint\n")
        defer { project.remove() }
        let missing = QualityToolsCheck(locator: try locator(project, installed: false))
        let report = await doctor(project).run(fix: true, checks: [missing], from: project.root)
        #expect(report.problems == [DoctorProblem(check: "quality-tools",
                                                  message: "swiftlint is not installed: it is not in PATH, /opt/homebrew/bin, or /usr/local/bin",
                                                  next: "brew install swiftlint, or set lint.path in .xcdev.local.yml")])
        #expect(report.failure?.next == "brew install swiftlint, or set lint.path in .xcdev.local.yml")

        let found = QualityToolsCheck(locator: try locator(project, installed: true))
        #expect(await doctor(project).run(fix: false, checks: [found], from: project.root).problems.isEmpty)
    }

    @Test func aPathThatNamesNothingIsAProblemEvenWhenTheToolIsInPath() async throws {
        let project = try setup(Self.base + "lint:\n  tool: swiftlint\n  path: tools/swiftlint\n")
        defer { project.remove() }
        let check = QualityToolsCheck(locator: try locator(project, installed: true))
        let report = await doctor(project).run(fix: false, checks: [check], from: project.root)
        #expect(report.problems.map(\.message) == ["lint.path names 'tools/swiftlint', which is not a file that can be run"])
        #expect(report.problems.first?.next == "fix lint.path in .xcdev.yml or .xcdev.local.yml, or remove it to have xcd look in PATH")
    }

    /// A project's own command and `tool: none` name no tool for doctor to look for.
    @Test func onlyANamedToolIsLookedFor() async throws {
        for section in ["lint:\n  run: ./scripts/lint.sh\n", "lint:\n  tool: none\n", ""] {
            let project = try setup(Self.base + section)
            defer { project.remove() }
            let check = QualityToolsCheck(locator: try locator(project, installed: false))
            #expect(await doctor(project).run(fix: false, checks: [check], from: project.root).problems.isEmpty)
        }
    }

    @Test func theChecksAreListedOnlyInAProjectWhoseConfigLoads() async throws {
        let project = try setup("version: 1\nproject: App.xcodeproj\nlint:\n  tool: nosuch\n")
        defer { project.remove() }
        try project.write("included:\n  - App\n", to: ".swiftlint.yml")
        let checks: [any DoctorCheck] = [QualitySetupCheck(), QualityToolsCheck()]
        #expect(await doctor(project).run(fix: true, checks: checks, from: project.root).checks.isEmpty)
        #expect(await doctor(project).run(fix: true, checks: checks, from: project.base).checks.isEmpty)       // outside a project
    }
}
