import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct DoctorTests {
    let fake = FakeProcessRunner()

    /// A project with its main worktree registered, simulators from the simctl-list fixture (no xcd devices yet),
    /// and git run for real.
    func setup(config: String = WorktreeServiceTests.config) async throws -> (TempProject, FakeSimulators, WorktreeService, WorktreeContext) {
        let project = try TempProject.make(config: config)
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        let worktrees = WorktreeService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home))
        return (project, sims, worktrees, try await worktrees.open(from: project.root))
    }

    func doctor(_ project: TempProject, discovery: XcodeDiscovery? = nil) -> DoctorService {
        DoctorService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                      discovery: discovery ?? XcodeDiscovery(runner: fake, applicationsDirectories: []), sleep: { _ in })
    }

    /// Records `udid` as the worktree's clone of `device`.
    func record(_ udid: String, as device: String, in ctx: inout WorktreeContext) throws {
        ctx.state.devices[device] = ProvisionedDevice(udid: udid, deviceType: "iPhone 18 Pro", deviceTypeIdentifier: "t",
                                                      runtime: "iOS 27.0", runtimeIdentifier: "r")
        try WorktreeStateStore.save(ctx.state, ctx.paths)
    }

    var pkillCalls: Int { fake.calls.filter { $0.argv.first == "pkill" }.count }

    @Test func aHealthyMachineHasNoProblems() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let report = await doctor(project).run(fix: false, from: nil)
        #expect(report.problems.isEmpty && report.failure == nil)
        #expect(report.checks.map(\.id) == ["coresimulator", "templates"])
        #expect(report.text.hasPrefix("doctor: 0 problems\nok       coresimulator\nok       templates\ndisk: "))
    }

    @Test func templatesMustBeShutDownAvailableAndUnique() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        let booted = sims.add(name: "xcd-template · iPhone 18 Pro · iOS 27.0", state: "Booted")
        let duplicate = "xcd-template · iPhone 16 · iOS 27.0"
        sims.add(name: duplicate)
        sims.add(name: duplicate, state: "Booted")
        let gone = sims.add(name: "xcd-template · iPhone 16 · iOS 26.5", isAvailable: false)
        let report = await doctor(project).run(fix: true, checks: [TemplatesCheck()], from: nil)
        #expect(report.problems.count == 3 && report.problems.allSatisfy { $0.fixed })
        let left = sims.devices.filter { $0.name.hasPrefix(SimNaming.templatePrefix) }
        #expect(left.filter { $0.name == duplicate }.map(\.state) == ["Shutdown"])      // the usable copy is kept
        #expect(left.first { $0.udid == booted }?.state == "Shutdown")
        #expect(!left.contains { $0.udid == gone })
    }

    @Test func templateProblemsAreOnlyReportedWithoutFix() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        sims.add(name: "xcd-template · iPhone 18 Pro · iOS 27.0", state: "Booted")
        let before = sims.devices
        let report = await doctor(project).run(fix: false, checks: [TemplatesCheck()], from: nil)
        #expect(report.problems.count == 1 && !report.problems[0].fixed)
        #expect(sims.devices == before)
        #expect(report.failure?.next == "run `xcd doctor --fix` to fix 1 of them")
    }

    @Test func anUnresponsiveCoreSimulatorIsRestarted() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let listing = Fixture.string("simctl-list.json")
        let restarted = Counter()
        fake.stub(["xcrun", "simctl", "list", "-j"]) { _ in
            restarted.value == 0 ? ProcessOutput(exitCode: 1, stderr: "Failed to initialize simulator device set.")
                                 : ProcessOutput(stdout: listing)
        }
        fake.stub(["pkill"]) { _ in restarted.increment(); return ProcessOutput() }
        let report = await doctor(project).run(fix: true, checks: [CoreSimulatorCheck()], from: nil)
        let problem = try #require(report.problems.first)
        #expect(problem.message == "CoreSimulator didn't answer `simctl list`: `xcrun simctl list` failed (exit 1): Failed to initialize simulator device set.")
        #expect(problem.fixed)
        #expect(fake.calls.contains { $0.argv == ["pkill", "-9", "-f", "com.apple.CoreSimulator.CoreSimulatorService"] })
    }

    @Test func aPersistentCoreSimulatorFailureIsOnlyReportedWithoutFix() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        fake.stub(["xcrun", "simctl", "list", "-j"], exitCode: 1, stderr: "Failed to initialize simulator device set.")
        fake.stub(["pkill"]) { _ in ProcessOutput() }
        let report = await doctor(project).run(fix: false, checks: [CoreSimulatorCheck()], from: nil)
        let problem = try #require(report.problems.first)
        #expect(problem.action == .restartCoreSimulator && !problem.fixed)
        #expect(fake.calls.filter { $0.argv == ["xcrun", "simctl", "list", "-j"] }.count == CoreSimulatorCheck.listAttempts)
        #expect(pkillCalls == 0)
        #expect(report.failure?.code == .doctorProblems)
    }

    /// One failed list is retried, so a blip never restarts CoreSimulator.
    @Test func aTransientListFailureIsRetriedNotRestarted() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let listing = Fixture.string("simctl-list.json")
        let lists = Counter()
        fake.stub(["xcrun", "simctl", "list", "-j"]) { _ in
            lists.increment() == 1 ? ProcessOutput(exitCode: 1, stderr: "Failed to initialize simulator device set.")
                                   : ProcessOutput(stdout: listing)
        }
        fake.stub(["pkill"]) { _ in ProcessOutput() }
        let report = await doctor(project).run(fix: true, checks: [CoreSimulatorCheck()], from: nil)
        #expect(report.problems.isEmpty && report.failure == nil)
        #expect(pkillCalls == 0)
    }

    /// A list that fails for a reason other than CoreSimulator (here xcrun can't find simctl) is reported with a
    /// `next:` line, and `--fix` doesn't restart CoreSimulator for it.
    @Test func aFailureOutsideCoreSimulatorIsNotFixedByRestarting() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        fake.stub(["xcrun", "simctl", "list", "-j"], exitCode: 72,
                  stderr: "xcrun: error: unable to find utility \"simctl\", not a developer tool or in PATH")
        fake.stub(["pkill"]) { _ in ProcessOutput() }
        let report = await doctor(project).run(fix: true, checks: [CoreSimulatorCheck()], from: nil)
        let problem = try #require(report.problems.first)
        #expect(problem.action == nil && problem.next != nil && !problem.fixed)
        #expect(problem.message.hasPrefix("simctl couldn't list simulators: `xcrun simctl list` failed (exit 72): xcrun: error:"))
        #expect(pkillCalls == 0)
    }

    /// With nothing on stderr, the error ends at its exit code, without "exit: 1" detail noise.
    @Test func aListFailureWithoutStderrEndsAtItsExitCode() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        fake.stub(["xcrun", "simctl", "list", "-j"], exitCode: 1)
        let env = await doctor(project).environment(from: nil)
        #expect(env.catalog == nil)
        #expect(env.catalogError == "`xcrun simctl list` failed (exit 1)")
    }

    @Test func reportText() {
        var fixed = DoctorProblem(check: "orphaned-clones", message: "xcd · A · x · iphone (U1) is orphaned: its worktree no longer exists",
                                  action: .deleteSimulator, fix: "shut it down and delete it", subject: "U1")
        fixed.fixed = true
        var failed = DoctorProblem(check: "incomplete-worktrees", message: "A/half at /w/half was left half-created",
                                   action: .discardWorktree, fix: "remove it")
        failed.fixError = "'half' has changes; inspect it"
        let manual = DoctorProblem(check: "project", message: "Xcode 26.4 is not installed (xcode_missing)",
                                   next: "set `xcode:` in .xcdev.yml to an installed version, e.g. \"27.0\"")
        let report = DoctorReport(fixMode: true, checks: [
            .init(id: "coresimulator", problems: []), .init(id: "incomplete-worktrees", problems: [failed]),
            .init(id: "orphaned-clones", problems: [fixed]), .init(id: "project", problems: [manual]),
        ], disk: DiskSummary(worktrees: [.init(project: "A", name: "main", bytes: 1_288_490_189)], clonesBytes: 3 * 1_073_741_824,
                             templatesBytes: 36_675_584))
        #expect(Renderer.report(report, command: "doctor", format: .text) == """
        doctor: 3 problems, 1 fixed
        ok       coresimulator
        failed   incomplete-worktrees  A/half at /w/half was left half-created  (fix failed: 'half' has changes; inspect it)
        fixed    orphaned-clones  xcd · A · x · iphone (U1) is orphaned: its worktree no longer exists
        problem  project  Xcode 26.4 is not installed (xcode_missing)  next: set `xcode:` in .xcdev.yml to an installed version, e.g. "27.0"
        disk: worktrees 1.2GB (A/main 1.2GB), clones 3.0GB, templates 35.0MB  (APFS clones are counted in full)
        next: set `xcode:` in .xcdev.yml to an installed version, e.g. "27.0"
        """)
        #expect(report.failure?.code == .doctorProblems && report.failure?.code.exitCode == 3)
    }
}
