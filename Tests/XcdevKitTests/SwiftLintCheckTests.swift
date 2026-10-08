import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd doctor` on a project whose .swiftlint.yml has SwiftLint search `.xcdev/` (see `SwiftLintConfigTests` for
/// which configs do).
@Suite struct SwiftLintCheckTests {
    let fake = FakeProcessRunner()

    /// A project with a valid .xcdev.yml, simulators from the simctl-list fixture, and git run for real.
    func setup() throws -> TempProject {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        return project
    }

    func doctor(_ project: TempProject) -> DoctorService {
        DoctorService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                      discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []))
    }

    static let lintProblem = ".swiftlint.yml doesn't exclude .xcdev/, so SwiftLint searches xcd's build folder on every run, "
        + "which can add minutes to a build"

    func lintConfig(_ project: TempProject) throws -> String {
        try String(contentsOfFile: project.root + "/.swiftlint.yml", encoding: .utf8)
    }

    /// SwiftLint searches hidden folders too, so it lints `.xcdev/` on every build unless its config excludes it.
    @Test func aSwiftLintConfigThatSearchesTheStateFolderIsAProblemWithAFix() async throws {
        let project = try setup()
        defer { project.remove() }
        try project.write("excluded:\n  - Pods\n", to: ".swiftlint.yml")

        let report = await doctor(project).run(fix: false, from: project.root)
        #expect(report.checks.map(\.id).last == "swiftlint")
        #expect(report.problems.filter { $0.check == "swiftlint" } == [
            DoctorProblem(check: "swiftlint", message: Self.lintProblem, action: .excludeFromSwiftLint,
                          fix: "add `.xcdev` to its `excluded` list", subject: project.root + "/.swiftlint.yml")])
        #expect(report.text.contains("problem  swiftlint  \(Self.lintProblem)  (--fix: add `.xcdev` to its `excluded` list)"))
        #expect(try lintConfig(project) == "excluded:\n  - Pods\n")              // reported only, without --fix

        let fixed = await doctor(project).run(fix: true, checks: [SwiftLintCheck()], from: project.root)
        #expect(fixed.problems.map(\.fixed) == [true] && fixed.failure == nil)
        #expect(fixed.text.contains("fixed    swiftlint  "))
        #expect(try lintConfig(project) == "excluded:\n  - Pods\n  - .xcdev\n")
        let after = await doctor(project).run(fix: false, checks: [SwiftLintCheck()], from: project.root)
        #expect(after.problems.isEmpty && after.text.contains("ok       swiftlint"))
    }

    @Test func aSwiftLintConfigDoctorCannotEditSaysWhatToAdd() async throws {
        let project = try setup()
        defer { project.remove() }
        try project.write("excluded: Pods\n", to: ".swiftlint.yml")
        let report = await doctor(project).run(fix: true, checks: [SwiftLintCheck()], from: project.root)
        #expect(report.problems == [DoctorProblem(check: "swiftlint", message: Self.lintProblem,
                                                  next: "add `.xcdev` to the `excluded` list in .swiftlint.yml")])
        #expect(report.failure?.next == "add `.xcdev` to the `excluded` list in .swiftlint.yml")
        #expect(try lintConfig(project) == "excluded: Pods\n")
    }

    @Test func theSwiftLintCheckIsOnlyForAProjectWithAConfigForIt() async throws {
        let project = try setup()
        defer { project.remove() }
        #expect(await doctor(project).run(fix: false, checks: [SwiftLintCheck()], from: project.root).checks.isEmpty)
        try project.write("included:\n  - App\n", to: ".swiftlint.yml")
        let report = await doctor(project).run(fix: true, checks: [SwiftLintCheck()], from: project.root)
        #expect(report.checks.map(\.id) == ["swiftlint"] && report.problems.isEmpty)
        #expect(try lintConfig(project) == "included:\n  - App\n")
        // Outside a project, a .swiftlint.yml is not xcd's to look at.
        try project.write("excluded:\n  - Pods\n", to: ".swiftlint.yml", in: project.base)
        #expect(await doctor(project).run(fix: false, checks: [SwiftLintCheck()], from: project.base).checks.isEmpty)
    }

    /// The file is read again for the fix, so an entry added since `detect` isn't added twice.
    @Test func aSwiftLintConfigCorrectedMeanwhileIsLeftAlone() async throws {
        let project = try setup()
        defer { project.remove() }
        try project.write("excluded:\n  - Pods\n", to: ".swiftlint.yml")
        let env = await doctor(project).environment(from: project.root, fixing: true)
        let problem = try #require(SwiftLintCheck().detect(env).first)
        try project.write("excluded:\n  - Pods\n  - .xcdev/\n", to: ".swiftlint.yml")
        #expect(throws: DoctorLeftAlone(note: ".swiftlint.yml no longer needs the entry; left alone")) {
            try SwiftLintCheck().fix(problem, env)
        }
        #expect(try lintConfig(project) == "excluded:\n  - Pods\n  - .xcdev/\n")
    }
}
