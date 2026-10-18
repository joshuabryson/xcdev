import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"

/// A worktree another tool made, on a branch with no .xcdev.yml, built with real xcodebuild.
/// A Swift package built for the Mac, so no simulator is involved.
@Suite(.enabled(if: enabled, "set XCD_INTEGRATION=1 to run (needs Xcode)"), .serialized)
struct AgentCheckoutIntegrationTests {
    @Test func aBranchWithoutConfigBuildsWithTheMainCheckoutsAndRemovingItLeavesTheCheckout() async throws {
        let hook = "hooks:\n  pre-build: 'echo ran >> \"$XCD_PROJECT_ROOT/../hook.log\"'\n"
        let project = try TempProject.make(config: "version: 1\nproject: Package.swift\n" + hook, name: "Borrowing \(UUID().uuidString.prefix(6))")
        defer { project.remove() }
        try project.write(WarningsIntegrationTests.package, to: "Package.swift")
        try project.write("public func login() -> Int { 1 }\n", to: "Sources/Lib/Login.swift")
        try project.write("import Testing\n@testable import Lib\n\n@Test func works() { #expect(login() == 1) }\n", to: "Tests/LibTests/LibTests.swift")
        try project.commit("Base")
        // Laid out as Codex lays its worktrees out: `<id>/<repository's folder name>`.
        let path = project.base + "/codex/a1b2/" + URL(fileURLWithPath: project.root).lastPathComponent
        try project.git("worktree", "add", "-q", "-b", "agent", path)
        try TempProject.git(["rm", "-q", ".xcdev.yml"], in: path)
        try TempProject.git(["-c", "user.name=xcd", "-c", "user.email=xcd@example.com", "commit", "-q", "-m", "No config"], in: path)

        let svc = Services(runner: SystemProcessRunner(), globalPaths: GlobalPaths(base: project.home), currentDirectory: path, environment: [:])
        var ctx = try await svc.open(worktree: nil)
        #expect(ctx.borrowedConfig == project.root + "/.xcdev.yml" && ctx.state.name.hasPrefix("a1b2-"))
        let build = try await svc.builds.build(BuildOptions(), in: &ctx)
        #expect(build.succeeded, "\(build.text)")
        #expect(svc.notes.all == ["this branch has no .xcdev.yml, so xcd uses the main checkout's (\(project.root)/.xcdev.yml); "
            + "its hooks don't run here until this branch has its own"])
        #expect(!FileManager.default.fileExists(atPath: project.base + "/hook.log"))      // the borrowed pre-build hook did not run

        let main = try await services(project).open(worktree: nil)
        let removal = try await svc.worktrees.remove(name: ctx.state.name, in: main)
        #expect(removal.keptCheckout && FileManager.default.fileExists(atPath: path + "/Package.swift"))
        #expect(!FileManager.default.fileExists(atPath: path + "/.xcdev"))
    }
}
