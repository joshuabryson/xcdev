import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// A project can start using SwiftLint long after `xcd init` ran, and a build is where a config that has SwiftLint
/// search `.xcdev/` costs its minutes. So the commands that build say so in their reports.
@Suite struct SetupNotesTests {
    static let note = ".swiftlint.yml doesn't exclude .xcdev/, so SwiftLint searches xcd's build folder on every run, "
        + "which can add minutes to a build; run `xcd doctor --fix`, or add `.xcdev` to the `excluded` list in .swiftlint.yml"

    /// Writes a .swiftlint.yml in the worktree, which doesn't exist before its context is made.
    func lint(_ yaml: String, in worktree: FakeWorktree) throws {
        try FileManager.default.createDirectory(atPath: worktree.root, withIntermediateDirectories: true)
        try yaml.write(toFile: worktree.root + "/.swiftlint.yml", atomically: true, encoding: .utf8)
    }

    @Test func aBuildNotesASwiftLintConfigThatSearchesTheStateFolder() async throws {
        let builds = BuildServiceTests()
        defer { builds.worktree.remove() }
        let (_, xcodebuild) = try builds.setUp()
        xcodebuild.onRun(.init(buildResults: Fixture.string("build-results-succeeded.json")))
        xcodebuild.onBuildSettings(Fixture.string("build-settings.json"))
        try lint("excluded:\n  - Pods\n", in: builds.worktree)
        var ctx = try builds.context()

        let report = try await builds.service().buildNotingSetup(BuildOptions(), in: &ctx)
        #expect(report.succeeded && report.notes.last == Self.note)                    // after what the build itself notes
        let lines = report.text.components(separatedBy: "\n")
        #expect(lines.dropLast().last == "note: " + Self.note && lines.last?.hasPrefix("log: ") == true)
        // The file is the project's: a build says what it found and leaves the edit to `init` and `doctor`.
        #expect(try String(contentsOfFile: builds.worktree.root + "/.swiftlint.yml", encoding: .utf8) == "excluded:\n  - Pods\n")

        try lint("excluded:\n  - Pods\n  - .xcdev\n", in: builds.worktree)
        let after = try await builds.service().buildNotingSetup(BuildOptions(), in: &ctx)
        #expect(after.succeeded && !after.notes.contains(Self.note) && !after.text.contains("SwiftLint"))
    }

    @Test func aFailedBuildCarriesTheNoteToo() async throws {
        let builds = BuildServiceTests()
        defer { builds.worktree.remove() }
        let (_, xcodebuild) = try builds.setUp()
        xcodebuild.onRun(.init(exitCode: 65, log: "** BUILD FAILED **\n", buildResults: Fixture.string("build-results-failed.json")))
        try lint("disabled_rules:\n  - todo\n", in: builds.worktree)
        var ctx = try builds.context()
        let report = try await builds.service().buildNotingSetup(BuildOptions(), in: &ctx)
        #expect(!report.succeeded && report.notes.last == Self.note)
    }

    @Test func aProjectWithoutSwiftLintGetsNoNote() async throws {
        let builds = BuildServiceTests()
        defer { builds.worktree.remove() }
        let (_, xcodebuild) = try builds.setUp()
        xcodebuild.onRun(.init(buildResults: Fixture.string("build-results-succeeded.json")))
        xcodebuild.onBuildSettings(Fixture.string("build-settings.json"))
        var ctx = try builds.context()
        let report = try await builds.service().buildNotingSetup(BuildOptions(), in: &ctx)
        #expect(report.succeeded && !report.notes.contains(Self.note) && !report.text.contains("SwiftLint"))
        #expect(!FileManager.default.fileExists(atPath: builds.worktree.root + "/.swiftlint.yml"))
    }

    @Test func runShowsItsBuildsNoteUnderTheBuildLine() async throws {
        let runs = RunServiceTests()
        defer { runs.worktree.remove() }
        _ = try runs.setUp()
        try lint("excluded:\n  - Pods\n", in: runs.worktree)
        var ctx = try runs.context()
        let report = try await runs.service().run(BuildOptions(), noBuild: false, launch: LaunchOptions(), in: &ctx)
        #expect(report.status == .running && report.build?.notes.last == Self.note)
        let lines = report.text.components(separatedBy: "\n")
        #expect(lines.first?.hasPrefix("build succeeded  scheme=App") == true)
        let note = try #require(lines.firstIndex(of: "note: " + Self.note))
        #expect(lines.prefix(note).allSatisfy { !$0.hasPrefix("launched ") })        // under the build line, before the launch
    }

    @Test func aTestRunNotesItWithItsOtherNotes() async throws {
        let tests = TestServiceTests()
        defer { tests.worktree.remove() }
        try lint("excluded:\n  - Pods\n", in: tests.worktree)
        let (report, _) = try await tests.run(.init(testSummary: TestServiceTests.passingSummary))
        #expect(report.outcome == .passed && report.notes.contains(Self.note))
        #expect(report.text.components(separatedBy: "\n").contains("note: " + Self.note))

        try lint("included:\n  - App\n", in: tests.worktree)
        #expect(try await !tests.run(.init(testSummary: TestServiceTests.passingSummary)).0.notes.contains(Self.note))
    }
}
