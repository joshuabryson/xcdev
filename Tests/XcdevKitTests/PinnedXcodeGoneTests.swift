import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// A worktree whose pinned Xcode is no longer there. `xcd doctor --fix` unpins it: the
/// formatter the project names is not what is wrong, so nothing points at `format.tool` in the shared config.
@Suite struct PinnedXcodeGoneTests {
    static func gone(in project: TempProject) -> XcodeInstall {
        XcodeInstall(path: project.base + "/Gone.app", version: "27.0", build: "27A1")
    }

    @Test func xcdFormatSaysTheWorktreesXcodeIsGoneAndThatDoctorUnpinsIt() async throws {
        let project = try FormatProject(FormatProject.appleSwiftFormat)
        defer { project.project.remove() }
        try project.change()
        var ctx = try await project.context()
        let gone = Self.gone(in: project.project)
        ctx.state.xcode = gone
        let formatters = FakeFormatters()
        let error = await #expect(throws: XcdError.self) { _ = try await project.service(formatters).format(FormatOptions(), in: ctx) }

        #expect(error?.code == .xcodeMissing && error?.code.exitCode == 3)
        #expect(error?.message == "the worktree's Xcode is gone: it is pinned to \(gone.path), which no longer exists")
        #expect(error?.next == "run `xcd doctor --fix`, which unpins it")
        #expect(project.xcrunCall == nil && formatters.runs.isEmpty)
        #expect(try project.read("Sources/App/C.swift") == "struct C {\n\tlet c = 1\n}")
    }

    /// SwiftFormat is not looked for in an Xcode, so a pin that is gone does not stop it.
    @Test func aFormatterThatIsNotInAnXcodeRunsAllTheSame() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        try project.change()
        var ctx = try await project.context()
        ctx.state.xcode = Self.gone(in: project.project)
        let report = try await project.service(FakeFormatters()).format(FormatOptions(), in: ctx)
        #expect(report.failure == nil && report.changed.count == 2)
    }

    /// The `project` check reports the pin and has the fix. A second problem about swift-format would send the
    /// reader to the formatter.
    @Test func doctorLeavesAPinnedXcodeThatIsGoneToTheProjectCheck() async throws {
        let checks = FormatChecksTests()
        let named = try checks.projectNaming(true)
        defer { named.project.remove() }
        let gone = Self.gone(in: named.project)
        let state = WorktreeState(id: "id", name: "main", project: "App", projectRoot: named.project.root, path: named.project.root,
                                  branch: nil, xcode: gone, devices: [:], status: .ready, createdAt: Date(timeIntervalSince1970: 1_790_040_000))
        try WorktreeStateStore.save(state, WorktreePaths(root: named.project.root))
        let report = await checks.quality.doctor(named.project).run(fix: false, checks: [named.check, ProjectCheck()], from: named.project.root)
        #expect(report.problems.map(\.check) == ["project"])
        #expect(report.problems.first?.message == "worktree 'main' is pinned to \(gone.summary), which is no longer installed")
        #expect(checks.lookedForSwiftFormat == nil)
    }
}
