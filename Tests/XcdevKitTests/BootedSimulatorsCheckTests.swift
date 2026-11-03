import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct BootedSimulatorsCheckTests: DoctorFixture {
    let fake = FakeProcessRunner()
    /// Every watchdog doctor starts, and every process it inspects, is on this fake: never a real process.
    let detached = FakeDetachedProcesses()
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    static let xcd = "/opt/xcd/bin/xcd"
    static let developerDir = "/Applications/Xcode-27.app/Contents/Developer"

    /// Doctor at `t0`, with the fake launcher and an xcd of its own.
    func doctor(_ project: TempProject) -> DoctorService {
        let now = t0
        return DoctorService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                             discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []), now: { now }, detached: detached,
                             accessibility: { FakeAccessibility(app: FakeApp(windows: [])) }, hostApp: { "TestHost" },
                             xcdExecutable: Self.xcd, sleep: { _ in /* doctor's pauses are skipped */ })
    }

    /// The doctor fixture, with `ps` listing no `launchd_sim`.
    func setUp() async throws -> (TempProject, FakeSimulators, WorktreeService, WorktreeContext) {
        let fixture = try await setup()
        psLists("")
        return fixture
    }

    func psLists(_ lines: String) {
        fake.stub(["ps", "-axo", "pid=,comm="], stdout: lines)
    }

    /// A clone of `ctx`'s worktree, Booted and recorded there as `device`. Returns its udid.
    func bootedClone(_ sims: FakeSimulators, as device: String = "iphone", in ctx: inout WorktreeContext) throws -> String {
        let udid = sims.add(name: SimNaming.clone(project: ctx.state.project, worktree: ctx.state.name, device: device), state: "Booted")
        try record(udid, as: device, in: &ctx)
        return udid
    }

    /// Saves a lease of `udid` booted 2h 10m before `t0` and renewed `quiet` seconds before it.
    func lease(_ udid: String, worktree: String = "main", quiet: TimeInterval, idle: Int = 600, root: String, home: String) throws {
        let lease = DeviceLease(udid: udid, device: "iphone", worktree: worktree, worktreeRoot: root, project: "Sample App",
                                developerDir: nil, bootedAt: t0 - 7800, renewedAt: t0 - quiet, idle: idle)
        try DeviceLeases(globalPaths: GlobalPaths(base: home)).save(lease)
    }

    /// A watchdog record of `udid` whose process the fake launcher runs.
    func liveWatchdog(_ udid: String, home: String) throws {
        let process = ProcessIdentity(pid: 4242, startTime: 1, arguments: [Self.xcd, Watchdogs.marker, udid])
        detached.adopt(process)
        let watchdogs = Watchdogs(leases: DeviceLeases(globalPaths: GlobalPaths(base: home)), detached: detached)
        try watchdogs.save(WatchdogRecord(process: process, udid: udid, startedAt: t0 - 7800, log: "/l"))
    }

    /// `ps` lists pid 812 as a `launchd_sim`.
    func launchdSim() {
        psLists("  1 /sbin/launchd\n  812 /Library/Developer/CoreSimulator/Volumes/iOS_23A/RuntimeRoot/sbin/launchd_sim\n")
    }

    func launchdSimStarted(_ secondsAgo: TimeInterval, for udid: String) {
        let plist = "/Users/u/Library/Developer/CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist"
        detached.adopt(ProcessIdentity(pid: 812, startTime: (t0 - secondsAgo).timeIntervalSince1970, arguments: ["launchd_sim", plist]))
    }

    @Test func nothingBootedSaysSo() async throws {
        let (project, _, _, _) = try await setUp()
        defer { project.remove() }
        let report = await doctor(project).run(fix: false, checks: [BootedSimulatorsCheck()], from: project.root)
        #expect(report.checks[0].summary == "none booted")
        #expect(report.text.contains("ok       booted-simulators  none booted"))
        #expect(!fake.calls.contains { $0.argv.first == "ps" })                      // nothing booted: no process listing
    }

    @Test func aWatchedCloneIsListedOk() async throws {
        var (project, sims, _, ctx) = try await setUp()
        defer { project.remove() }
        let clone = try bootedClone(sims, in: &ctx)
        try lease(clone, quiet: 180, root: ctx.paths.root, home: project.home)
        try liveWatchdog(clone, home: project.home)
        let report = await doctor(project).run(fix: false, checks: [BootedSimulatorsCheck()], from: project.root)
        #expect(report.checks[0].summary == "1 booted: Sample App/main iphone 2h 10m (used 3m ago, idle 10m, watchdog running)")
        #expect(report.problems.isEmpty)
    }

    @Test func aCloneWithoutAWatchdogIsThisProjectsProblem() async throws {
        var (project, sims, _, ctx) = try await setUp()
        defer { project.remove() }
        let clone = try bootedClone(sims, in: &ctx)
        try lease(clone, quiet: 1500, root: ctx.paths.root, home: project.home)
        let report = await doctor(project).run(fix: false, checks: [BootedSimulatorsCheck()], from: project.root)
        let problem = try #require(report.problems.first)
        #expect(problem.message == "Sample App/main iphone: booted 2h 10m, used 25m ago, no watchdog")
        #expect(problem.action == .startWatchdog)
        #expect(problem.next == "run `xcd doctor --fix` to start one")
        #expect(problem.scope == .project)
        #expect(report.text.contains("ok       booted-simulators  1 booted: Sample App/main iphone 2h 10m (no watchdog)"))
    }

    @Test func anotherProjectsCloneIsListedElsewhere() async throws {
        let (project, sims, worktrees, _) = try await setUp()
        defer { project.remove() }
        let other = try TempProject.make(config: WorktreeServiceTests.config, name: "Other")
        defer { other.remove() }
        var otherCtx = try await worktrees.open(from: other.root)
        _ = try bootedClone(sims, in: &otherCtx)
        let report = await doctor(project).run(fix: false, checks: [BootedSimulatorsCheck()], from: project.root)
        let otherRoot = otherCtx.state.projectRoot
        #expect(report.elsewhere.first?.next == "ask the user before running `xcd doctor --fix` in \(otherRoot)")
        #expect(report.elsewhere.first?.message == "Other/main iphone: no watchdog")
        #expect(report.here.isEmpty)
    }

    @Test func aSimulatorXcdDidNotBootIsAProblemOnlyPastADay() async throws {
        let (project, sims, _, _) = try await setUp()
        defer { project.remove() }
        let u9 = sims.add(name: "iPhone 17 Pro", state: "Booted")
        launchdSim()
        launchdSimStarted(90_000, for: u9)
        let report = await doctor(project).run(fix: false, checks: [BootedSimulatorsCheck()], from: project.root)
        let problem = try #require(report.elsewhere.first)
        #expect(problem.message == "iPhone 17 Pro (not xcd's): booted 1d 1h")
        #expect(problem.action == nil)
        #expect(problem.next == "ask the user before shutting it down: `xcrun simctl shutdown \(u9)`")
        #expect(report.here.isEmpty)

        launchdSimStarted(18_000, for: u9)
        let younger = await doctor(project).run(fix: false, checks: [BootedSimulatorsCheck()], from: project.root)
        #expect(younger.problems.isEmpty)
        #expect(younger.checks[0].summary == "1 booted: iPhone 17 Pro 5h 0m (not xcd's)")
    }

    @Test func aSimulatorWhoseProcessCannotBeReadHasNoAge() async throws {
        let (project, sims, _, _) = try await setUp()
        defer { project.remove() }
        let udid = sims.add(name: "iPhone 17 Pro", state: "Booted")
        launchdSim()                                                                 // the fake inspector knows no pid 812
        let report = await doctor(project).run(fix: false, checks: [BootedSimulatorsCheck()], from: project.root)
        #expect(report.checks[0].summary == "1 booted: iPhone 17 Pro (not xcd's)")
        #expect(report.problems.isEmpty)
        launchdSimStarted(60, for: udid)                                             // once pid 812 can be read, it has an age
        let readable = await doctor(project).run(fix: false, checks: [BootedSimulatorsCheck()], from: project.root)
        #expect(readable.checks[0].summary == "1 booted: iPhone 17 Pro 1m (not xcd's)")
    }

    @Test func idleOffIsNeverAProblem() async throws {
        var (project, sims, _, ctx) = try await setUp()
        defer { project.remove() }
        let clone = try bootedClone(sims, in: &ctx)
        try lease(clone, quiet: 180, idle: 0, root: ctx.paths.root, home: project.home)
        let report = await doctor(project).run(fix: false, checks: [BootedSimulatorsCheck()], from: project.root)
        #expect(report.checks[0].summary == "1 booted: Sample App/main iphone 2h 10m (used 3m ago, idle off: never shuts down)")
        #expect(report.problems.isEmpty)
    }

    @Test func fixStartsAWatchdogForThisProjectsCloneOnly() async throws {
        var (project, sims, worktrees, ctx) = try await setUp()
        defer { project.remove() }
        ctx.state.xcode = XcodeInstall(path: "/Applications/Xcode-27.app", version: "27.0", build: "27A1")
        let mine = try bootedClone(sims, in: &ctx)
        let other = try TempProject.make(config: WorktreeServiceTests.config, name: "Other")
        defer { other.remove() }
        var otherCtx = try await worktrees.open(from: other.root)
        _ = try bootedClone(sims, in: &otherCtx)
        let report = await doctor(project).run(fix: true, checks: [BootedSimulatorsCheck()], from: project.root)
        #expect(detached.starts.map(\.invocation.arguments) == [["_watch-device", mine, "--developer-dir", Self.developerDir]])
        #expect(detached.starts.first?.invocation.executable == Self.xcd)
        #expect(report.here.first?.fixed == true)
        #expect(report.elsewhere.first?.fixed == false)
        #expect(report.checks[0].summary?.contains("Sample App/main iphone 0s (used 0s ago, idle 10m, watchdog running)") == true)
    }

    @Test func fixWritesALeaseWhenNoneExists() async throws {
        var (project, sims, _, ctx) = try await setUp()
        defer { project.remove() }
        let mine = try bootedClone(sims, in: &ctx)
        _ = await doctor(project).run(fix: true, checks: [BootedSimulatorsCheck()], from: project.root)
        let lease = try #require(DeviceLeases(globalPaths: GlobalPaths(base: project.home)).load(mine))
        #expect(lease.renewedAt == t0 && lease.idle == 600)
        #expect(lease.bootedAt == t0 && lease.worktreeRoot == ctx.paths.root && lease.device == "iphone")
    }

    @Test func aNewLeaseIsBootedWhenItsLaunchdSimStarted() async throws {
        var (project, sims, _, ctx) = try await setUp()
        defer { project.remove() }
        let mine = try bootedClone(sims, in: &ctx)
        launchdSim()
        launchdSimStarted(10_800, for: mine)
        _ = await doctor(project).run(fix: true, checks: [BootedSimulatorsCheck()], from: project.root)
        let lease = try #require(DeviceLeases(globalPaths: GlobalPaths(base: project.home)).load(mine))
        #expect(lease.bootedAt == t0 - 10_800 && lease.renewedAt == t0)
    }

    @Test func fixKeepsTheLeaseItFinds() async throws {
        var (project, sims, _, ctx) = try await setUp()
        defer { project.remove() }
        let mine = try bootedClone(sims, in: &ctx)
        try lease(mine, quiet: 1500, idle: 1200, root: ctx.paths.root, home: project.home)
        let report = await doctor(project).run(fix: true, checks: [BootedSimulatorsCheck()], from: project.root)
        let kept = try #require(DeviceLeases(globalPaths: GlobalPaths(base: project.home)).load(mine))
        #expect(kept.renewedAt == t0 - 1500 && kept.idle == 1200 && kept.bootedAt == t0 - 7800)
        #expect(detached.starts.count == 1)
        #expect(report.text.contains("fixed    booted-simulators  Sample App/main iphone: booted 2h 10m, used 25m ago, no watchdog  (watchdog started)"))
    }

    @Test func aLaunchdSimStartOutranksTheLease() async throws {
        var (project, sims, _, ctx) = try await setUp()
        defer { project.remove() }
        let mine = try bootedClone(sims, in: &ctx)
        try lease(mine, quiet: 180, root: ctx.paths.root, home: project.home)       // booted 2h 10m ago, says the lease
        try liveWatchdog(mine, home: project.home)
        launchdSim()
        launchdSimStarted(10_800, for: mine)
        let report = await doctor(project).run(fix: false, checks: [BootedSimulatorsCheck()], from: project.root)
        #expect(report.checks[0].summary == "1 booted: Sample App/main iphone 3h 0m (used 3m ago, idle 10m, watchdog running)")
    }

    @Test func aCloneOfAWorktreeBeingCreatedOrRemovedIsLeftAlone() async throws {
        var (project, sims, worktrees, ctx) = try await setUp()
        defer { project.remove() }
        let mine = try bootedClone(sims, in: &ctx)
        let env = await doctor(project).environment(from: project.root, fixing: true)
        let problem = try #require(await BootedSimulatorsCheck().detect(env).first)
        let holder = try await holdLock(worktrees.lockPath(projectRoot: ctx.state.projectRoot, worktree: ctx.state.name))
        await #expect(throws: DoctorLeftAlone(note: "Sample App/main is being created or removed by another xcd; left alone")) {
            try await BootedSimulatorsCheck().fix(problem, env)
        }
        holder.cancel()
        _ = await holder.result
        #expect(detached.starts.isEmpty)
        #expect(DeviceLeases(globalPaths: GlobalPaths(base: project.home)).load(mine) == nil)
    }

    @Test func aCloneForgottenBetweenDetectAndFixGetsNoWatchdog() async throws {
        var (project, sims, _, ctx) = try await setUp()
        defer { project.remove() }
        let mine = try bootedClone(sims, in: &ctx)
        let env = await doctor(project).environment(from: project.root, fixing: true)
        let problem = try #require(await BootedSimulatorsCheck().detect(env).first)
        ctx.state.devices = [:]                                                      // another xcd erased the clone meanwhile
        try WorktreeStateStore.save(ctx.state, ctx.paths)
        try await BootedSimulatorsCheck().fix(problem, env)
        #expect(detached.starts.isEmpty)
        #expect(DeviceLeases(globalPaths: GlobalPaths(base: project.home)).load(mine) == nil)
    }

    @Test func aCloneNoWorktreeRecordsIsNotAdopted() async throws {
        let (project, sims, _, _) = try await setUp()
        defer { project.remove() }
        let clone = sims.add(name: "xcd · Sample App · gone · iphone", state: "Booted")
        try lease(clone, worktree: "gone", quiet: 60, root: project.base + "/Sample App.worktrees/gone", home: project.home)
        let report = await doctor(project).run(fix: true, checks: [BootedSimulatorsCheck()], from: project.root)
        #expect(report.problems.isEmpty)
        #expect(report.checks[0].summary?.contains("(no watchdog)") == true)
        #expect(detached.starts.isEmpty)
    }

    @Test func checksWithoutASummaryKeepTheirJSONAndText() async throws {
        let (project, _, _, _) = try await setUp()
        defer { project.remove() }
        let report = await doctor(project).run(fix: false, checks: [OrphanedClonesCheck()], from: project.root)
        #expect(report.text.contains("ok       orphaned-clones\n") || report.text.hasSuffix("ok       orphaned-clones"))
        #expect(!Renderer.report(report, command: "doctor", format: .json, notes: []).contains("summary"))
    }

    @Test func aSummaryLeadsItsChecksLinesAndReachesTheJSON() async throws {
        var (project, sims, _, ctx) = try await setUp()
        defer { project.remove() }
        let clone = try bootedClone(sims, in: &ctx)
        try lease(clone, quiet: 1500, root: ctx.paths.root, home: project.home)
        let report = await doctor(project).run(fix: false, checks: [BootedSimulatorsCheck()], from: project.root, includeDisk: false)
        #expect(report.text == """
            doctor: 1 problem
            ok       booted-simulators  1 booted: Sample App/main iphone 2h 10m (no watchdog)
            problem  booted-simulators  Sample App/main iphone: booted 2h 10m, used 25m ago, no watchdog  \
            (--fix: start its idle watchdog)  next: run `xcd doctor --fix` to start one
            """)
        #expect(Renderer.report(report, command: "doctor", format: .json, notes: []).contains(#""summary":"1 booted: "#))
    }

    @Test func ageText() {
        #expect([5, 59, 60, 1500, 3599, 3600, 7800, 86_399, 86_400, 90_000, 273_600].map { BootedSimulator.duration(TimeInterval($0)) }
                == ["5s", "59s", "1m", "25m", "59m", "1h 0m", "2h 10m", "23h 59m", "1d 0h", "1d 1h", "3d 4h"])
    }

    @Test func pidsByNameMatchTheLastPathComponentExactly() async throws {
        fake.stub(["ps", "-axo", "pid=,comm="],
                  stdout: "  812 /R/sbin/launchd_sim\n  813 /R/sbin/launchd_sim_helper\n 9 launchd_sim\n  1 /sbin/launchd\n")
        #expect(try await ProcessLookup(runner: fake).pids(named: "launchd_sim") == [812, 9])
    }
}
