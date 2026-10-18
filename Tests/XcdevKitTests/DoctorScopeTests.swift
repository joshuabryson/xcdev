import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Whose each problem doctor finds is: this project's, another project's, a gone project's, xcd's, or the Mac's.
@Suite struct DoctorScopeTests: DoctorFixture {
    let fake = FakeProcessRunner()

    func problem(in root: String?) -> DoctorProblem {
        DoctorProblem(check: "some-check", message: "something", action: .dropRegistryEntry, fix: "drop it", projectRoot: root)
    }

    @Test func aProblemIsThisProjectsAnotherProjectsOrAGoneProjects() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let other = project.base + "/Other", gone = project.base + "/Gone", moved = project.base + "/Moved"
        let unmounted = "/Volumes/xcd-no-such-volume-\(UUID().uuidString)/Away"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: project.base + "/Moved.worktrees/feat", withIntermediateDirectories: true)
        try await register("main", of: other, at: other, home: project.home)
        try await register("feat", of: gone, at: project.base + "/Gone.worktrees/feat", home: project.home)
        try await register("feat", of: moved, at: project.base + "/Moved.worktrees/feat", home: project.home)
        try await register("main", of: unmounted, at: unmounted, home: project.home)
        // Its main checkout is gone, and its only other checkout is on a volume that is not mounted: not gone for sure.
        let stranded = project.base + "/Stranded"
        let away = "/Volumes/xcd-no-such-volume-\(UUID().uuidString)/Stranded.worktrees/feat"
        try await register("feat", of: stranded, at: away, home: project.home)

        let roots: [String?] = [project.root, other, gone, moved, unmounted, stranded, nil]
        let inside = DoctorScopes(env: await doctor(project).environment(from: project.root))
        let scoped = inside.assign(roots.map(problem(in:)), reach: .entries)
        #expect(scoped.map(\.scope) == [.project, .otherProject, .goneProject, .otherProject, .otherProject, .otherProject, .otherProject])
        #expect(scoped.map(\.projectRoot) == roots)
        // Outside any project, no problem is this project's.
        let outside = DoctorScopes(env: await doctor(project).environment(from: nil))
        #expect(outside.assign([problem(in: project.root)], reach: .entries).map(\.scope) == [.otherProject])
    }

    /// Git decides which project doctor runs in, not `.xcdev.yml`: without one, the checkout's own problems are still its own.
    @Test func aCheckoutWithoutAConfigIsStillThisProject() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        try FileManager.default.removeItem(atPath: project.root + "/.xcdev.yml")
        try await register("gone", of: project.root, at: project.base + "/Sample App.worktrees/gone", home: project.home)
        let plain = await doctor(project).run(fix: false, checks: [MissingWorktreesCheck()], from: project.root, includeDisk: false)
        let problem = try #require(plain.problems.first)
        #expect(problem.scope == .project && problem.projectRoot == project.root)
        #expect(plain.text.contains("  (--fix: "))
        let fixed = await doctor(project).run(fix: true, checks: [MissingWorktreesCheck()], from: project.root, includeDisk: false)
        #expect(fixed.problems.map(\.fixed) == [true])
        #expect(try Registry(paths: GlobalPaths(base: project.home)).entries().map(\.name) == ["main"])
    }

    /// Agents work in worktrees: from one, the project is the same as from its main checkout.
    @Test func aWorktreeOfTheProjectIsThisProjectToo() async throws {
        let (project, _, worktrees, main) = try await setup()
        defer { project.remove() }
        let (feat, _) = try await worktrees.create(name: "feat", in: main)
        try FileManager.default.createDirectory(atPath: feat.path + "/Sources", withIntermediateDirectories: true)
        let scopes = DoctorScopes(env: await doctor(project).environment(from: feat.path + "/Sources"))
        #expect(scopes.assign([problem(in: project.root)], reach: .entries).map(\.scope) == [.project])
        #expect(scopes.assign([DoctorProblem(check: "c", message: "m")], reach: .thisProject).map(\.projectRoot) == [project.root])
    }

    @Test func theOtherChecksAreXcdsTheMacsOrThisProjects() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let scopes = DoctorScopes(env: await doctor(project).environment(from: project.root))
        let some = DoctorProblem(check: "c", message: "m")
        #expect(scopes.assign([some], reach: .xcd).map(\.scope) == [.xcd])
        #expect(scopes.assign([some], reach: .mac).map(\.scope) == [.mac])
        let own = scopes.assign([some], reach: .thisProject)
        #expect(own.map(\.scope) == [.project] && own.map(\.projectRoot) == [project.root])
        let reaches = DoctorService.allChecks.map { "\($0.id)=\($0.reach)" }
        #expect(reaches == ["project=thisProject", "coresimulator=mac", "missing-worktrees=entries", "incomplete-worktrees=entries", "orphaned-clones=entries",
                            "stuck-clones=entries", "templates=xcd", "recordings=entries", "ui-runners=entries", "init-scratch=xcd",
                            "package-caches=xcd", "quality-setup=thisProject", "quality-tools=thisProject", "project=thisProject",
                            "swiftlint=thisProject"])
    }

    @Test func worktreeAndCloneProblemsNameTheirProject() async throws {
        var (project, sims, _, ctx) = try await setup()
        defer { project.remove() }
        try await register("gone", of: project.root, at: project.base + "/Sample App.worktrees/gone", home: project.home)
        let stuck = sims.add(name: "xcd · Sample App · main · iphone", state: "Shutting Down")
        try record(stuck, as: "iphone", in: &ctx)
        let orphan = sims.add(name: "xcd · Sample App · gone · iphone")
        let report = await doctor(project).run(fix: false, from: nil)
        let found = report.problems.filter { ["missing-worktrees", "stuck-clones", "orphaned-clones"].contains($0.check) }
        #expect(found.map(\.check) == ["missing-worktrees", "orphaned-clones", "stuck-clones"])
        #expect(found.allSatisfy { $0.projectRoot == project.root && $0.scope == .otherProject })      // doctor ran outside it
        #expect(found.compactMap(\.subject).contains(orphan))
    }

    @Test func anUnreadableRegistryIsXcds() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        try "{nope".write(toFile: GlobalPaths(base: project.home).registryFile, atomically: true, encoding: .utf8)
        let report = await doctor(project).run(fix: false, checks: [MissingWorktreesCheck()], from: project.root)
        #expect(report.problems.map(\.scope) == [.xcd] && report.problems.first?.projectRoot == nil)
    }

    /// Clone names carry only the project's folder name, so two projects of the same name cannot be told apart.
    @Test func aCloneOfAGoneWorktreeOfOneOfTwoSameNamedProjectsIsNeverFixed() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        let one = project.base + "/one/Twin", two = project.base + "/two/Twin"
        try FileManager.default.createDirectory(atPath: two, withIntermediateDirectories: true)
        try await register("old", of: one, at: project.base + "/one/Twin.worktrees/old", home: project.home)
        try await register("main", of: two, at: two, home: project.home)
        let twin = sims.add(name: "xcd · Twin · old · iphone", state: "Booted")
        let own = sims.add(name: "xcd · Sample App · old · iphone")

        let report = await doctor(project).run(fix: true, checks: [OrphanedClonesCheck()], from: project.root)
        let ambiguous = try #require(report.problems.first { $0.subject == twin })
        #expect(ambiguous.action == nil && !ambiguous.fixed && ambiguous.projectRoot == nil && ambiguous.scope == .otherProject)
        #expect(ambiguous.message == "xcd · Twin · old · iphone (\(twin)) is orphaned: projects at \(one) and \(two) share its project's name, "
                    + "so xcd cannot tell whose it is")
        #expect(ambiguous.next == "ask the user before deleting it: `xcrun simctl shutdown \(twin); xcrun simctl delete \(twin)`")
        #expect(sims.devices.contains { $0.udid == twin && $0.state == "Booted" })
        // A gone worktree of a project with a name of its own is still that project's.
        let gone = try #require(report.problems.first { $0.subject == own })
        #expect(gone.projectRoot == project.root && gone.scope == .project && gone.fixed)
    }

    @Test func theScopeAndProjectAreInTheJSON() throws {
        var problem = DoctorProblem(check: "orphaned-clones", message: "m", projectRoot: "/p/Gone")
        problem.scope = .goneProject
        let json = String(decoding: try JSONCoding.encoder(pretty: false).encode(problem), as: UTF8.self)
        #expect(json.contains(#""scope":"gone-project""#) && json.contains(#""projectRoot":"/p/Gone""#))
    }
}
