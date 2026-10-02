import Foundation
import Synchronization
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

    func doctor(_ project: TempProject, discovery: XcodeDiscovery? = nil,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) -> DoctorService {
        DoctorService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                      discovery: discovery ?? XcodeDiscovery(runner: fake, applicationsDirectories: []), sleep: sleep)
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
        #expect(report.checks.map(\.id) == ["coresimulator", "missing-worktrees", "incomplete-worktrees", "orphaned-clones",
                                            "stuck-clones", "templates"])        // no project check outside a project
        #expect(report.text.hasPrefix("doctor: 0 problems\nok       coresimulator\n"))
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

    @Test func orphanedClonesAreReportedAndDeletedOnlyWithFix() async throws {
        var (project, sims, _, main) = try await setup()
        defer { project.remove() }
        let owned = sims.add(name: "xcd · Sample App · main · iphone")
        try record(owned, as: "iphone", in: &main)
        let gone = sims.add(name: "xcd · Sample App · deleted · iphone")
        let other = sims.add(name: "xcd · Other · main · iphone")
        // A clone of a registered worktree made a moment ago may be another agent's provisioning in flight.
        let young = project.base + "/young-device"
        try FileManager.default.createDirectory(atPath: young, withIntermediateDirectories: true)
        let inFlight = sims.add(name: "xcd · Sample App · main · ipad", dataPath: young + "/data")

        let before = sims.devices
        let report = await doctor(project).run(fix: false, from: nil)
        let orphans = report.problems.filter { $0.check == "orphaned-clones" }
        #expect(orphans.compactMap(\.subject).sorted() == [gone, other].sorted())
        #expect(orphans.first { $0.subject == gone }?.message == "xcd · Sample App · deleted · iphone (\(gone)) is orphaned: its worktree no longer exists")
        #expect(report.failure?.code == .doctorProblems)
        #expect(report.failure?.next == "run `xcd doctor --fix` to fix 2 of them")
        #expect(sims.devices == before)                                           // nothing changed without --fix

        let fixed = await doctor(project).run(fix: true, from: nil)
        #expect(fixed.problems.filter(\.fixed).count == 2 && fixed.failure == nil)
        #expect(Set(sims.devices.map(\.udid)).isSuperset(of: [owned, inFlight]))
        #expect(!sims.devices.contains { $0.udid == gone || $0.udid == other })
    }

    /// An unrecorded clone of a registered worktree is spared only while it is young.
    @Test func anOldUnrecordedCloneOfARegisteredWorktreeIsOrphaned() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        let folder = project.base + "/old-device"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-601)], ofItemAtPath: folder)
        let old = sims.add(name: "xcd · Sample App · main · ipad", dataPath: folder + "/data")
        let report = await doctor(project).run(fix: false, checks: [OrphanedClonesCheck()], from: nil)
        #expect(report.problems.map(\.message) == ["xcd · Sample App · main · ipad (\(old)) is orphaned: Sample App/main doesn't record it"])
    }

    /// With the registry unreadable, every clone would look orphaned, so none is touched.
    @Test func aLostRegistryNeverDeletesClones() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        let clone = sims.add(name: "xcd · Sample App · main · iphone")
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: GlobalPaths(base: project.home).registryFile))

        let report = await doctor(project).run(fix: true, from: nil)
        #expect(sims.devices.contains { $0.udid == clone })
        #expect(report.problems.filter { $0.check == "orphaned-clones" }.isEmpty)
        let unreadable = try #require(report.problems.first { $0.check == "missing-worktrees" })
        #expect(unreadable.message.hasSuffix("registry.json is corrupt") && unreadable.action == nil && unreadable.next != nil)
        #expect(report.failure?.code == .doctorProblems)
    }

    @Test func aWorktreeDeletedByHandLeavesNothingBehindAfterFix() async throws {
        let (project, sims, worktrees, main) = try await setup()
        defer { project.remove() }
        var (feat, _) = try await worktrees.create(name: "feat", in: main)
        let clone = sims.add(name: "xcd · Sample App · feat · iphone")
        feat.devices["iphone"] = ProvisionedDevice(udid: clone, deviceType: "P", deviceTypeIdentifier: "p", runtime: "iOS", runtimeIdentifier: "r")
        try WorktreeStateStore.save(feat, WorktreePaths(root: feat.path))
        try FileManager.default.removeItem(atPath: feat.path)

        let report = await doctor(project).run(fix: true, from: nil)
        #expect(report.problems.map(\.check) == ["missing-worktrees", "orphaned-clones"])
        #expect(report.problems.allSatisfy { $0.fixed })
        #expect(try worktrees.list(projectRoot: project.root).map(\.name) == ["main"])
        #expect(!sims.devices.contains { $0.udid == clone })
        #expect(await doctor(project).run(fix: false, from: nil).problems.isEmpty)
    }

    /// Dropping a missing worktree re-checks it under its locks and prunes git's record of it.
    @Test func droppingAMissingWorktreeRechecksItUnderItsLocks() async throws {
        let (project, _, worktrees, main) = try await setup()
        defer { project.remove() }
        let (feat, _) = try await worktrees.create(name: "feat", in: main)
        let (back, _) = try await worktrees.create(name: "back", in: main)
        try FileManager.default.removeItem(atPath: feat.path)
        let metadata = project.root + "/.git/worktrees/feat"                // git's record of the checkout
        #expect(FileManager.default.fileExists(atPath: metadata))

        try await worktrees.dropMissing(id: feat.id)
        #expect(try worktrees.list(projectRoot: project.root).map(\.name) == ["back", "main"])
        #expect(!FileManager.default.fileExists(atPath: metadata))

        try await worktrees.dropMissing(id: back.id)                     // its checkout is there: kept
        #expect(try worktrees.list(projectRoot: project.root).map(\.name) == ["back", "main"])

        try FileManager.default.removeItem(atPath: back.path)
        let holder = try await holdLock(worktrees.lockPath(projectRoot: project.root, worktree: "back"))
        await #expect(throws: DoctorLeftAlone.self) { try await worktrees.dropMissing(id: back.id) }
        holder.cancel()
        _ = await holder.result
        #expect(try worktrees.list(projectRoot: project.root).map(\.name) == ["back", "main"])
    }

    /// What `xcd wt create <name>` leaves after `git worktree add`, whether it was killed there or is still running
    /// its post-worktree-create hook: an incomplete entry, checkout, and state. Returns the checkout's path.
    func halfCreated(_ name: String, in project: TempProject) async throws -> String {
        let path = project.base + "/Sample App.worktrees/" + name
        try TempProject.git(["worktree", "add", "-b", name, path, "HEAD"], in: project.root)
        let state = WorktreeState(id: name + "-id", name: name, project: "Sample App", projectRoot: project.root,
                                  path: Paths.canonical(path), branch: name, xcode: nil, devices: [:], status: .incomplete,
                                  createdAt: Date())
        try WorktreeStateStore.save(state, WorktreePaths(root: state.path))
        try await Registry(paths: GlobalPaths(base: project.home)).upsert(RegistryEntry(state))
        return path
    }

    /// Holds the lock at `path` (as another xcd's `wt create` or `wt remove` would) from before this returns until
    /// the task is cancelled or `lease` runs out. The lease turns a doctor that waits for the lock into a failing
    /// test instead of a hung one.
    func holdLock(_ path: String, lease: Duration = .seconds(20)) async throws -> Task<Void, any Error> {
        let (acquired, signal) = AsyncStream<Void>.makeStream()
        let holder = Task {
            defer { signal.finish() }
            try await FileLock.withLock(at: path) {
                signal.yield()
                try await Task.sleep(for: lease)
            }
        }
        for await _ in acquired { break }
        return holder
    }

    @Test func aWorktreeLeftHalfCreatedIsRemoved() async throws {
        let (project, _, worktrees, _) = try await setup()
        defer { project.remove() }
        let path = try await halfCreated("half", in: project)

        let report = await doctor(project).run(fix: true, from: nil)
        let problem = try #require(report.problems.first { $0.check == "incomplete-worktrees" })
        #expect(problem.fixed)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try worktrees.list(projectRoot: project.root).map(\.name) == ["main"])
    }

    /// `wt create` runs post-worktree-create (up to 30 minutes) holding only the worktree's lock, not the project's.
    @Test(.timeLimit(.minutes(1))) func aWorktreeStillBeingCreatedIsLeftAlone() async throws {
        let (project, _, worktrees, _) = try await setup()
        defer { project.remove() }
        let path = try await halfCreated("busy", in: project)
        let note = "Sample App/busy is being created or removed by another xcd; left alone"

        let holder = try await holdLock(worktrees.lockPath(projectRoot: project.root, worktree: "busy"))
        let report = await doctor(project).run(fix: true, from: nil)
        holder.cancel()
        _ = await holder.result
        #expect(report.problems.isEmpty && report.failure == nil)
        #expect(report.checks.first { $0.id == "incomplete-worktrees" }?.inProgress == [note])
        #expect(report.text.contains("\nbusy     incomplete-worktrees  \(note)\n"))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try worktrees.list(projectRoot: project.root).map(\.name) == ["busy", "main"])

        // Once that create is gone (killed), the same entry is a half-created worktree.
        let later = await doctor(project).run(fix: true, from: nil)
        #expect(later.problems.first { $0.check == "incomplete-worktrees" }?.fixed == true)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test(.timeLimit(.minutes(1))) func aWorktreeBeingRemovedIsLeftToItsRemove() async throws {
        let (project, _, worktrees, main) = try await setup()
        defer { project.remove() }
        let (feat, _) = try await worktrees.create(name: "feat", in: main)
        try FileManager.default.removeItem(atPath: feat.path)
        // `wt remove feat` after deleting the checkout, before dropping the entry: it holds the worktree's lock.
        let holder = try await holdLock(worktrees.lockPath(projectRoot: main.location.projectRoot, worktree: "feat"))
        let report = await doctor(project).run(fix: true, checks: DoctorService.pruneChecks, from: nil, includeDisk: false)
        holder.cancel()
        _ = await holder.result
        #expect(report.problems.isEmpty)
        #expect(report.checks.first?.inProgress == ["Sample App/feat is being created or removed by another xcd; left alone"])
        #expect(try worktrees.list(projectRoot: project.root).map(\.name) == ["feat", "main"])
    }

    /// The lock is probed once per snapshot, so detect and inProgress always agree, even if
    /// the lock is released between them.
    @Test(.timeLimit(.minutes(1))) func theBusyProbeIsTakenOncePerSnapshot() async throws {
        let (project, _, worktrees, _) = try await setup()
        defer { project.remove() }
        _ = try await halfCreated("busy", in: project)
        let holder = try await holdLock(worktrees.lockPath(projectRoot: project.root, worktree: "busy"))
        let env = await doctor(project).environment(from: nil)
        holder.cancel()
        _ = await holder.result
        #expect(env.busy == ["busy-id"])
        #expect(await IncompleteWorktreesCheck().detect(env).isEmpty)
        #expect(IncompleteWorktreesCheck().inProgress(env) == ["Sample App/busy is being created or removed by another xcd; left alone"])
    }

    /// Doctor never waits for a worktree's lock.
    @Test(.timeLimit(.minutes(1))) func withLockIfFreeNeverWaits() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        let path = project.home + "/locks/probe.lock"
        #expect(!FileLock.isHeld(at: path))
        #expect(!FileManager.default.fileExists(atPath: path))                // probing never creates the file
        #expect(try await FileLock.withLockIfFree(at: path) { 7 } == 7)
        let holder = try await holdLock(path)
        #expect(FileLock.isHeld(at: path))
        #expect(try await FileLock.withLockIfFree(at: path) { 7 } == nil)
        holder.cancel()
        _ = await holder.result
        #expect(!FileLock.isHeld(at: path))
    }

    @Test func stuckAndUnavailableClonesAreShutDownOrRecloned() async throws {
        var (project, sims, _, main) = try await setup()
        defer { project.remove() }
        let stuck = sims.add(name: "xcd · Sample App · main · iphone", state: "Booting")
        let broken = sims.add(name: "xcd · Sample App · main · watch", isAvailable: false)
        try record(stuck, as: "iphone", in: &main)
        try record(broken, as: "watch", in: &main)
        let slept = Mutex(Duration.zero)

        let report = await doctor(project, sleep: { d in slept.withLock { $0 += d } }).run(fix: true, from: nil)
        #expect(report.problems.filter { $0.check == "stuck-clones" }.map(\.message).sorted() == [
            "xcd · Sample App · main · iphone (\(stuck)) is stuck in Booting",
            "xcd · Sample App · main · watch (\(broken)) is unavailable; its runtime may have been removed",
        ])
        #expect(report.problems.filter { $0.check == "stuck-clones" }.allSatisfy { $0.fixed })
        #expect(sims.devices.first { $0.udid == stuck }?.state == "Shutdown")
        #expect(!sims.devices.contains { $0.udid == broken })
        let saved = try #require(try WorktreeStateStore.load(main.paths))
        #expect(saved.devices.keys.sorted() == ["iphone"])                    // the watch is cloned again on next use
        // 5s to call it stuck, then up to 2 minutes for a cold boot to finish before shutting it down.
        #expect(slept.withLock { $0 } >= .seconds(5) + StuckClonesCheck.settleTimeout)
    }

    /// A cold boot can take minutes, so the fix waits before shutting a clone down.
    @Test func aCloneThatFinishesBootingDuringTheFixIsLeftAlone() async throws {
        var (project, sims, _, main) = try await setup()
        defer { project.remove() }
        let booting = sims.add(name: "xcd · Sample App · main · iphone", state: "Booting")
        try record(booting, as: "iphone", in: &main)
        let naps = Counter()
        let simulators = sims
        let service = doctor(project, sleep: { _ in
            if naps.increment() == 3 { simulators.setState("Booted", udid: booting) }   // the second poll of the fix sees it
        })

        let report = await service.run(fix: true, checks: [StuckClonesCheck()], from: nil, includeDisk: false)
        #expect(report.problems.isEmpty && report.failure == nil)
        #expect(report.checks.first?.inProgress == ["xcd · Sample App · main · iphone (\(booting)) is now Booted; left alone"])
        #expect(sims.devices.first { $0.udid == booting }?.state == "Booted")
        #expect(!fake.calls.contains { $0.argv.starts(with: ["xcrun", "simctl", "shutdown"]) })
        #expect(try WorktreeStateStore.load(main.paths)?.devices["iphone"]?.udid == booting)
    }

    @Test func aCloneThatWontShutDownIsDeleted() async throws {
        var (project, sims, _, main) = try await setup()
        defer { project.remove() }
        let stuck = sims.add(name: "xcd · Sample App · main · iphone", state: "Shutting Down")
        try record(stuck, as: "iphone", in: &main)
        fake.stub(["xcrun", "simctl", "shutdown"], exitCode: 149, stderr: "Unable to shutdown device in current state: Shutting Down")
        let report = await doctor(project).run(fix: true, checks: [StuckClonesCheck()], from: nil)
        #expect(report.problems.first?.fixed == true)
        #expect(!sims.devices.contains { $0.udid == stuck })
        #expect(try WorktreeStateStore.load(main.paths)?.devices.isEmpty == true)
    }

    /// Forgetting a clone edits worktree.json as it is on disk now, not as the snapshot saw it.
    @Test func forgettingAClonesReloadsTheWorktreeState() async throws {
        var (project, _, _, main) = try await setup()
        defer { project.remove() }
        try record("U-IPHONE", as: "iphone", in: &main)
        try record("U-WATCH", as: "watch", in: &main)
        let env = await doctor(project).environment(from: nil)
        try record("U-IPAD", as: "ipad", in: &main)                    // another agent records a clone meanwhile

        try env.forget(udid: "U-IPHONE")
        try env.forget(udid: "U-WATCH")                                 // from the same, now stale, snapshot
        let saved = try #require(try WorktreeStateStore.load(main.paths))
        #expect(saved.devices.mapValues(\.udid) == ["ipad": "U-IPAD"])
    }

    @Test func pruneOnlyLooksForOrphans() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        sims.add(name: "xcd-template · iPhone 18 Pro · iOS 27.0", state: "Booted")
        let orphan = sims.add(name: "xcd · Gone · x · iphone")
        let report = await doctor(project).run(fix: true, checks: DoctorService.pruneChecks, from: nil, includeDisk: false)
        #expect(report.checks.map(\.id) == ["missing-worktrees", "orphaned-clones"])
        #expect(report.problems.count == 1 && report.problems[0].subject == orphan && report.problems[0].fixed)
        #expect(report.disk == nil)
    }
}
