import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"
private let commit = ["-c", "user.name=xcd", "-c", "user.email=xcd@example.com", "commit"]

@Suite(.enabled(if: enabled, "set XCD_INTEGRATION=1 to run (needs Xcode + an iOS simulator runtime)"), .serialized)
struct SetupDoctorIntegrationTests {
    /// The SampleApp fixture as a fresh git repo with no .xcdev.yml, so `init` has to write one.
    func bareAppProject() throws -> TempProject {
        let project = try TempProject.make(config: "version: 1\nproject: SampleApp.xcodeproj\n",
                                           name: "Setup App \(UUID().uuidString.prefix(6))",
                                           fixture: repoRoot + "/Fixtures/SampleApp", parent: testsHome)
        try FileManager.default.removeItem(atPath: project.root + "/.xcdev.yml")
        try TempProject.git(commit + ["-qam", "No config"], in: project.root)
        return project
    }

    /// The round trip: init → wt create → build → run → logs → wt remove → doctor reports nothing to fix.
    /// Doctor runs without --fix: this test's private XCDEV_HOME makes every other registry's clones look orphaned.
    @Test func initWorktreeBuildRunLogsRemoveThenDoctorIsClean() async throws {
        let project = try bareAppProject()
        try await withCleanup(project) { svc in
            let plan = try await svc.setup.plan(from: project.root)
            #expect(plan.detected.platforms == [.iOS] && plan.detected.appSchemes == ["SampleApp"], "\(plan.text)")
            let written = try await svc.setup.write(answers: [:], force: false, from: project.root)
            #expect(written.status == .written, "\(written.text)")
            try TempProject.git(["add", ".xcdev.yml", ".gitignore"], in: project.root)
            try TempProject.git(commit + ["-qm", "Add xcdev"], in: project.root)

            let main = try await svc.open(worktree: nil)
            let agent = try await svc.worktrees.create(name: "agent", in: main).state
            var ctx = try await svc.worktrees.open(from: agent.path)
            let build = try await svc.builds.build(BuildOptions(), in: &ctx)
            #expect(build.succeeded, "\(build.text)")
            let run = try await svc.apps.run(BuildOptions(), noBuild: true, launch: LaunchOptions(), in: &ctx)
            #expect(run.status == .running, "\(run.text)")
            let output = try await svc.logs.logs(LogOptions(appOutput: true), in: &ctx)
            #expect(output.lines.contains { $0.hasPrefix("SampleApp launched") }, "\(output.text)")
            let removal = try await svc.worktrees.remove(name: "agent", force: true, in: main)
            #expect(removal.removedDevices == ["iphone"])

            let doctor = await svc.doctor.run(fix: false, from: project.root)
            let name = URL(fileURLWithPath: project.root).lastPathComponent
            // Other projects' simulators on this Mac are not this test's business.
            let ours = doctor.problems.filter { $0.message.contains(name) || $0.check == "project" }
            #expect(ours.isEmpty, "\(doctor.text)")
        }
    }
}
