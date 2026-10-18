import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// What `xcd doctor --fix` and `--restart-simulators` may repair, and what doctor says about the rest.
@Suite struct DoctorReachTests: DoctorFixture {
    let fake = FakeProcessRunner()

    /// Another project, registered in `project`'s xcd home with its main worktree, as opening it there would.
    func another(_ project: TempProject, named name: String) async throws -> TempProject {
        let other = try TempProject.make(config: WorktreeServiceTests.config, name: name)
        _ = try await WorktreeService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home)).open(from: other.root)
        return other
    }

    /// The clone is listed in progress, still booting, and was neither shut down nor deleted.
    func expectLeftBooting(_ report: DoctorReport, _ udid: String, _ sims: FakeSimulators) {
        #expect(report.checks.first?.inProgress.count == 1 && report.checks.first?.inProgress.first?.contains("is Booting, which can take") == true)
        #expect(sims.devices.first { $0.udid == udid }?.state == "Booting")
        #expect(!fake.calls.contains { $0.argv.starts(with: ["xcrun", "simctl", "shutdown"]) || $0.argv.starts(with: ["xcrun", "simctl", "delete"]) })
    }

    @Test func fixInOneProjectLeavesAnothersCloneAloneAndSaysWhereToFixIt() async throws {
        let (project, sims, _, _) = try await setup()
        let nearby = try await another(project, named: "Nearby")
        defer { project.remove(); nearby.remove() }
        let clone = sims.add(name: "xcd · Nearby · spike · iphone")
        let plain = await doctor(project).run(fix: false, checks: [OrphanedClonesCheck()], from: project.root, includeDisk: false)
        let problem = try #require(plain.problems.first)
        #expect(problem.scope == .otherProject && problem.projectRoot == nearby.root && problem.action == .deleteSimulator)
        #expect(plain.text.hasSuffix("elsewhere (not this project's to fix; ask the user):\n"
                    + "problem  orphaned-clones  \(problem.message)  next: ask the user before running `xcd doctor --fix` in \(nearby.root)"))
        #expect(plain.failure == nil)
        for fixed in [await doctor(project).run(fix: true, checks: [OrphanedClonesCheck()], from: project.root),
                      await doctor(project).run(fix: true, checks: DoctorService.pruneChecks, from: project.root)] {
            #expect(fixed.problems.map(\.fixed) == [false] && fixed.failure == nil)
        }
        #expect(sims.devices.contains { $0.udid == clone })
        let there = await doctor(project).run(fix: true, checks: [OrphanedClonesCheck()], from: nearby.root)
        #expect(there.problems.map(\.fixed) == [true] && !sims.devices.contains { $0.udid == clone })
    }

    /// Restarting CoreSimulator shuts down every agent's simulators, so plain `--fix` never does it.
    @Test func onlyRestartSimulatorsRestartsCoreSimulator() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let restarted = coreSimulatorThatAnswersOnceRestarted()
        let plain = await doctor(project).run(fix: true, checks: [CoreSimulatorCheck()], from: project.root)
        let problem = try #require(plain.problems.first)
        #expect(!problem.fixed && problem.scope == .mac && restarted.value == 0)
        #expect(plain.text.contains("  (--restart-simulators: restart the CoreSimulator service; every booted simulator on this Mac shuts down)"))
        #expect(plain.failure?.next
                    == "ask the user before running `xcd doctor --restart-simulators`: it shuts down every booted simulator on this Mac, other agents' too")
        let restart = await doctor(project).run(fix: false, restartSimulators: true, checks: [CoreSimulatorCheck()], from: project.root)
        #expect(restart.problems.map(\.fixed) == [true] && restarted.value == 1)
        let answering = await doctor(project).run(fix: false, restartSimulators: true, checks: [CoreSimulatorCheck()], from: project.root)
        #expect(answering.problems.isEmpty && restarted.value == 1 && answering.text.contains("\nok       coresimulator"))
    }

    /// Nobody can be working in a project none of whose checkouts is there, so its leftovers go from anywhere.
    @Test func aGoneProjectsLeftoversAreFixedFromAnywhere() async throws {
        let (project, sims, _, _) = try await setup()
        let old = try await another(project, named: "Old")
        defer { project.remove(); old.remove() }
        let clone = sims.add(name: "xcd · Old · main · iphone")
        try FileManager.default.removeItem(atPath: old.root)
        let report = await doctor(project).run(fix: true, checks: DoctorService.pruneChecks, from: nil, includeDisk: false)
        #expect(report.problems.map(\.scope) == [.goneProject, .goneProject] && report.problems.allSatisfy(\.fixed))
        #expect(!sims.devices.contains { $0.udid == clone })
        #expect(try Registry(paths: GlobalPaths(base: project.home)).entries().map(\.project) == ["Sample App"])
    }

    /// A main checkout that was moved leaves its worktrees behind, where someone may be working.
    @Test func aProjectWhoseMainCheckoutMovedIsLeftToTheUser() async throws {
        let (project, sims, worktrees, _) = try await setup()
        let moved = try await another(project, named: "Moved")
        defer { project.remove(); moved.remove() }
        let (feat, _) = try await worktrees.create(name: "feat", in: try await worktrees.open(from: moved.root))
        let clone = sims.add(name: "xcd · Moved · gone · iphone")
        try FileManager.default.moveItem(atPath: moved.root, toPath: moved.base + "/Elsewhere")
        let report = await doctor(project).run(fix: true, checks: DoctorService.pruneChecks, from: project.root, includeDisk: false)
        let ask = "Moved's main checkout is no longer at \(moved.root), but \(feat.path) still is: ask the user whether it was moved or deleted"
        #expect(report.problems.map(\.next) == [ask, ask] && report.problems.allSatisfy { !$0.fixed && $0.scope == .otherProject })
        #expect(sims.devices.contains { $0.udid == clone })
    }

    @Test func aProjectOnAVolumeThatIsNotMountedSaysToMountIt() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let away = "/Volumes/xcd-unmounted-\(UUID().uuidString)/Away"
        try await register("feat", of: away, at: project.base + "/Away.worktrees/feat", home: project.home)
        let report = await doctor(project).run(fix: true, checks: DoctorService.pruneChecks, from: project.root, includeDisk: false)
        let problem = try #require(report.problems.first)
        #expect(!problem.fixed && problem.scope == .otherProject)
        #expect(problem.next == "\(away) can't be reached: it may be on a volume that isn't mounted, or in a folder xcd may not look into; "
                    + "ask the user to mount it or fix its permissions, then run `xcd doctor` again")
    }

    /// In a worktree whose main checkout was moved, doctor cannot tell which problems are this project's.
    @Test func doctorThatCannotTellWhichProjectItIsInFixesNothing() async throws {
        let (project, sims, worktrees, main) = try await setup()
        let old = try await another(project, named: "Old")
        defer { project.remove(); old.remove() }
        let (feat, _) = try await worktrees.create(name: "feat", in: main)
        let clone = sims.add(name: "xcd · Old · main · iphone")
        try FileManager.default.removeItem(atPath: old.root)
        try FileManager.default.moveItem(atPath: project.root, toPath: project.base + "/Moved App")
        let report = await doctor(project).run(fix: true, restartSimulators: true, checks: DoctorService.pruneChecks, from: feat.path,
                                               includeDisk: false)
        let located = try #require(report.problems.first)
        #expect(located.check == "project" && located.message.hasPrefix("this checkout is a git worktree, and its repository is no longer at "))
        #expect(located.message.hasSuffix(" (git_failed)"))
        #expect(located.next?.hasSuffix("; until git can find this project, `xcd doctor --fix` repairs nothing") == true)
        // Old's leftovers, and this project's main checkout that is no longer where the registry says, are not fixed.
        #expect(report.problems.dropFirst().map(\.check) == ["missing-worktrees", "missing-worktrees", "orphaned-clones"])
        #expect(report.problems.allSatisfy { !$0.fixed })
        #expect(report.failure?.next == located.next)
        #expect(sims.devices.contains { $0.udid == clone })
    }

    /// CoreSimulator belongs to no project, so a restart does not need doctor to know which one it is in; `--fix` still
    /// repairs nothing then.
    @Test func aRestartDoesNotNeedDoctorToKnowItsProject() async throws {
        let (project, _, worktrees, main) = try await setup()
        defer { project.remove() }
        let (feat, _) = try await worktrees.create(name: "feat", in: main)
        try FileManager.default.moveItem(atPath: project.root, toPath: project.base + "/Moved App")
        let restarted = coreSimulatorThatAnswersOnceRestarted()
        let plain = await doctor(project).run(fix: true, checks: [CoreSimulatorCheck()], from: feat.path, includeDisk: false)
        #expect(plain.problems.map(\.fixed) == [false] && restarted.value == 0)
        #expect(plain.text.contains("(--restart-simulators: "))
        let report = await doctor(project).run(fix: true, restartSimulators: true, checks: [CoreSimulatorCheck()] + DoctorService.pruneChecks,
                                               from: feat.path, includeDisk: false)
        #expect(report.problems.first { $0.check == "coresimulator" }?.fixed == true && restarted.value == 1)
        #expect(report.problems.filter { $0.check != "coresimulator" }.allSatisfy { !$0.fixed })
    }

    /// A run that only restarts CoreSimulator counts what it fixed, as a `--fix` run does.
    @Test func aRestartOnlyRunCountsWhatItFixed() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        _ = coreSimulatorThatAnswersOnceRestarted()
        let report = await doctor(project).run(fix: false, restartSimulators: true, checks: [CoreSimulatorCheck()], from: project.root, includeDisk: false)
        #expect(report.text.hasPrefix("doctor: 1 problem, 1 fixed\nfixed    coresimulator"))
    }

    /// `--fix` waits out a boot only where it reaches the clone's project; elsewhere a booting clone is in progress, as
    /// under plain `doctor`, and nothing tells the agent to go and fix it.
    @Test func anotherProjectsBootingCloneIsInProgressUnderFix() async throws {
        let (project, sims, worktrees, _) = try await setup()
        let nearby = try await another(project, named: "Nearby")
        defer { project.remove(); nearby.remove() }
        var nearbyMain = try await worktrees.open(from: nearby.root)
        let booting = sims.add(name: "xcd · Nearby · main · iphone", state: "Booting")
        try record(booting, as: "iphone", in: &nearbyMain)
        let report = await doctor(project).run(fix: true, checks: [StuckClonesCheck()], from: project.root, includeDisk: false)
        #expect(report.problems.isEmpty && report.failure == nil)
        expectLeftBooting(report, booting, sims)
    }

    @Test func aBootingCloneIsInProgressWhenDoctorCannotTellWhichProjectItIsIn() async throws {
        let (project, sims, worktrees, main) = try await setup()
        defer { project.remove() }
        var (feat, _) = try await worktrees.create(name: "feat", in: main)
        let booting = sims.add(name: "xcd · Sample App · feat · iphone", state: "Booting")
        feat.devices["iphone"] = ProvisionedDevice(udid: booting, deviceType: "P", deviceTypeIdentifier: "p", runtime: "iOS", runtimeIdentifier: "r")
        try WorktreeStateStore.save(feat, WorktreePaths(root: feat.path))
        try FileManager.default.moveItem(atPath: project.root, toPath: project.base + "/Moved App")
        let report = await doctor(project).run(fix: true, checks: [StuckClonesCheck()], from: feat.path, includeDisk: false)
        #expect(report.problems.filter { $0.check == "stuck-clones" }.isEmpty)
        expectLeftBooting(report, booting, sims)
    }

    @Test func theNextSaysWhatPlainFixReachesAndToAskBeforeARestart() {
        func scoped(_ problem: DoctorProblem, _ scope: DoctorProblem.Scope) -> DoctorProblem {
            var problem = problem
            problem.scope = scope
            return problem
        }
        let mac = scoped(DoctorProblem(check: "coresimulator", message: "CoreSimulator didn't answer", action: .restartCoreSimulator,
                                       fix: "restart the CoreSimulator service; every booted simulator on this Mac shuts down"), .mac)
        let own = scoped(DoctorProblem(check: "orphaned-clones", message: "own", action: .deleteSimulator, fix: "shut it down and delete it"), .project)
        let nearby = scoped(DoctorProblem(check: "orphaned-clones", message: "nearby", action: .deleteSimulator, fix: "shut it down and delete it",
                                         next: "ask the user before running `xcd doctor --fix` in /p/Nearby"), .otherProject)
        let report = DoctorReport(fixMode: false, checks: [.init(id: "coresimulator", problems: [mac]),
                                                           .init(id: "orphaned-clones", problems: [own, nearby])], disk: nil)
        #expect(report.text == """
            doctor: 2 problems, 1 elsewhere
            problem  coresimulator  CoreSimulator didn't answer  (--restart-simulators: restart the CoreSimulator service; every booted simulator on this Mac shuts down)
            problem  orphaned-clones  own  (--fix: shut it down and delete it)
            elsewhere (not this project's to fix; ask the user):
            problem  orphaned-clones  nearby  next: ask the user before running `xcd doctor --fix` in /p/Nearby
            """)
        #expect(report.failure?.next == "run `xcd doctor --fix` to fix 1 of them; the others say what to do; "
                    + "ask the user before running `xcd doctor --restart-simulators`: it shuts down every booted simulator on this Mac, other agents' too")
    }
}
