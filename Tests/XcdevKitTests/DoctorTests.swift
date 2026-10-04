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
                                            "stuck-clones", "templates", "recordings", "init-scratch", "package-caches"])   // no project check outside a project
        #expect(report.text.hasPrefix("doctor: 0 problems\nok       coresimulator\n"))
    }

    func recording(_ device: String, pid: Int32, startedAt: Date, in ctx: WorktreeContext) throws -> ProcessIdentity {
        let id = ProcessIdentity(pid: pid, startTime: 1, arguments: ["simctl", "io", "recordVideo"])
        try Recordings.save(RecordingRecord(device: device, udid: "U", path: ctx.paths.root + "/\(device).mp4", log: "/l",
                                            process: id, startedAt: startedAt), to: ctx.paths.recordingFile(device: device))
        return id
    }

    @Test func recordingsLeftBehindOrOverdueAreFixedOthersAreBusy() async throws {
        let (project, _, _, ctx) = try await setup()
        defer { project.remove() }
        let detached = FakeDetachedProcesses()
        let now = Date()
        _ = try recording("ended", pid: 1, startedAt: now, in: ctx)                                   // process gone
        detached.adopt(try recording("overdue", pid: 2, startedAt: now.addingTimeInterval(-3600), in: ctx))
        detached.adopt(try recording("fresh", pid: 3, startedAt: now, in: ctx))
        let service = DoctorService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                                    discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []), detached: detached)

        let report = await service.run(fix: false, from: nil)
        let check = try #require(report.checks.first { $0.id == "recordings" })
        #expect(check.problems.map(\.action) == [.forgetRecording, .stopRecording])
        #expect(check.problems[1].message.contains("has been recording overdue for 1h00m"))
        #expect(check.inProgress.count == 1 && check.inProgress[0].contains("is recording fresh to "))
        #expect(detached.stops.isEmpty)

        let fixed = await service.run(fix: true, from: nil)
        #expect(fixed.checks.first { $0.id == "recordings" }?.problems.allSatisfy(\.fixed) == true)
        #expect(detached.stops == [.init(pid: 2, signal: SIGINT)])
        #expect(ctx.paths.recordingFiles == [ctx.paths.recordingFile(device: "fresh")])
    }

    @Test func diskUsageIncludesTheMediaFolder() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        try FileManager.default.createDirectory(atPath: project.root + "/.xcdev-media/main/main", withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: URL(fileURLWithPath: project.root + "/.xcdev-media/main/main/a.png"))
        let service = DoctorService(runner: RoutingRunner(fake: fake, realExecutables: ["git", "cp", "du"]),
                                    globalPaths: GlobalPaths(base: project.home),
                                    discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []))
        let disk = try #require(await service.run(fix: false, from: nil).disk)
        #expect(disk.mediaBytes >= 300_000)
        #expect(disk.text.contains(", media "))
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

    /// Simctl answered, but its JSON didn't parse. The decoding error's coding path names a
    /// CoreSimulator runtime, which must not read as CoreSimulator's failure: a restart wouldn't help.
    @Test func aListThatDoesNotParseIsNotFixedByRestarting() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        fake.stub(["xcrun", "simctl", "list", "-j"],
                  stdout: #"{"devicetypes": [], "runtimes": [], "devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [{"udid": 7}]}}"#)
        fake.stub(["pkill"]) { _ in ProcessOutput() }
        let report = await doctor(project).run(fix: true, checks: [CoreSimulatorCheck()], from: nil)
        let problem = try #require(report.problems.first)
        #expect(problem.message.hasPrefix("simctl couldn't list simulators: could not parse `simctl list -j` output: "))
        #expect(problem.message.contains("com.apple.CoreSimulator.SimRuntime.iOS-27-0"))
        #expect(problem.action == nil && problem.next != nil && !problem.fixed)
        #expect(pkillCalls == 0)
    }

    /// A `simctl list` that times out means the service is hung, so it isn't retried, and `--fix`
    /// restarts it.
    @Test func aListThatTimesOutIsFixedByRestartingAtOnce() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let listing = Fixture.string("simctl-list.json")
        let restarted = Counter()
        fake.stub(["xcrun", "simctl", "list", "-j"]) { inv in
            guard restarted.value > 0 else {
                throw XcdError.subprocess(inv, ProcessOutput(exitCode: 15), code: .timeout,
                                          message: "`xcrun simctl list` timed out after 120 seconds")
            }
            return ProcessOutput(stdout: listing)
        }
        fake.stub(["pkill"]) { _ in restarted.increment(); return ProcessOutput() }
        let report = await doctor(project).run(fix: true, checks: [CoreSimulatorCheck()], from: nil)
        let problem = try #require(report.problems.first)
        #expect(problem.action == .restartCoreSimulator && problem.fixed)
        #expect(pkillCalls == 1)
        let lists = fake.calls.map(\.argv).prefix { $0.first != "pkill" }.filter { $0 == ["xcrun", "simctl", "list", "-j"] }
        #expect(lists.count == 1)                                               // no retries before the restart
    }

    /// Stderr that merely mentions a connection isn't CoreSimulator's broken connection.
    @Test func anUnrelatedConnectionErrorIsNotFixedByRestarting() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        fake.stub(["xcrun", "simctl", "list", "-j"], exitCode: 1,
                  stderr: "error: could not open a connection to the license agreement server")
        fake.stub(["pkill"]) { _ in ProcessOutput() }
        let report = await doctor(project).run(fix: true, checks: [CoreSimulatorCheck()], from: nil)
        #expect(report.problems.first?.action == nil)
        #expect(pkillCalls == 0)
        // A connection to the service that broke still counts.
        for stderr in ["CoreSimulatorService connection became invalid", "Connection interrupted", "The connection was invalidated"] {
            let failure = XcdError(.simulatorFailed, "`xcrun simctl list` failed (exit 1)",
                                   details: ["command: xcrun simctl list -j", "exit: 1", stderr])
            #expect(CoreSimulatorCheck.isCoreSimulatorFailure(failure), "\(stderr)")
        }
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
        #expect(report.failure?.next == "run `xcd doctor --fix` to fix 1 of them; the others say what to do")
        #expect(sims.devices == before)                                           // nothing changed without --fix

        // `other` is from a project this registry doesn't know: maybe another XCDEV_HOME's, so it is only reported.
        let fixed = await doctor(project).run(fix: true, from: nil)
        #expect(fixed.problems.filter(\.fixed).map(\.subject) == [gone])
        #expect(fixed.remaining.map(\.subject) == [other] && fixed.remaining[0].fixError == nil)
        #expect(Set(sims.devices.map(\.udid)).isSuperset(of: [owned, inFlight, other]))
        #expect(!sims.devices.contains { $0.udid == gone })
    }

    /// Makes `path`'s folder look created `seconds` ago, and returns a dataPath inside it.
    func agedDevice(_ path: String, seconds: TimeInterval) throws -> String {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: path)
        return path + "/data"
    }

    /// With no registry.json (a fresh or different XCDEV_HOME), no clone has a known owner,
    /// so none is deleted; each is reported with the command to delete it by hand.
    @Test func aMissingRegistryNeverDeletesClones() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        try FileManager.default.removeItem(atPath: GlobalPaths(base: project.home).registryFile)
        let clone = sims.add(name: "xcd · Sample App · main · iphone",
                             dataPath: try agedDevice(project.base + "/old-device", seconds: 3600))

        let report = await doctor(project).run(fix: true, from: nil)
        #expect(sims.devices.contains { $0.udid == clone })
        let problem = try #require(report.problems.first { $0.check == "orphaned-clones" })
        #expect(problem.message == "xcd · Sample App · main · iphone (\(clone)) is orphaned: no worktree in this registry is from its project")
        #expect(problem.next == "it may belong to another xcd state folder (XCDEV_HOME); if not, delete it with `xcrun simctl delete \(clone)`")
        #expect(problem.action == nil && !problem.fixed && problem.fixError == nil)
        #expect(report.failure?.next == problem.next)
        #expect(!fake.calls.contains { $0.argv.starts(with: ["xcrun", "simctl", "delete"]) })
    }

    /// A clone of a known project whose worktree is no longer registered is deleted, however old it is.
    @Test func aCloneOfAKnownProjectsGoneWorktreeIsDeleted() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        let clone = sims.add(name: "xcd · Sample App · gone · iphone",
                             dataPath: try agedDevice(project.base + "/old-device", seconds: 601))
        let report = await doctor(project).run(fix: true, checks: [OrphanedClonesCheck()], from: nil)
        #expect(report.problems.map(\.message) == ["xcd · Sample App · gone · iphone (\(clone)) is orphaned: its worktree no longer exists"])
        #expect(report.problems.allSatisfy { $0.fixed } && report.failure == nil)
        #expect(!sims.devices.contains { $0.udid == clone })
    }

    /// Deleting a whole project folder by hand drops its last registry entry during the fix. Its clones
    /// were that entry's, so they are still deleted in the same run rather than becoming of unknown owner.
    @Test func aProjectDeletedByHandLeavesNothingBehindAfterFix() async throws {
        let (project, sims, worktrees, _) = try await setup()
        defer { project.remove() }
        let solo = try TempProject.make(config: WorktreeServiceTests.config, name: "Solo")
        defer { try? FileManager.default.removeItem(atPath: solo.base) }
        var soloMain = try await worktrees.open(from: solo.root)                 // Solo's only registry entry
        let clone = sims.add(name: "xcd · Solo · main · iphone")
        try record(clone, as: "iphone", in: &soloMain)
        try FileManager.default.removeItem(atPath: solo.base)

        let report = await doctor(project).run(fix: true, from: nil)
        #expect(report.problems.map(\.check) == ["missing-worktrees", "orphaned-clones"])
        #expect(report.problems.allSatisfy { $0.fixed } && report.failure == nil)
        #expect(try worktrees.list(projectRoot: nil).map(\.project) == ["Sample App"])
        #expect(!sims.devices.contains { $0.udid == clone })
        #expect(await doctor(project).run(fix: false, from: nil).problems.isEmpty)
    }

    /// Project names are folder names, so two checkouts of one repo each have a
    /// "Sample App/main". Their clones look the same; one is spared if either worktree would spare it.
    @Test func aCloneIsSparedIfAnyWorktreeOfItsNameWouldSpareIt() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        // A second checkout named "Sample App", registered after ours, whose worktree.json can't be read.
        let twin = project.base + "/zz/Sample App"
        try FileManager.default.createDirectory(atPath: twin + "/.xcdev", withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: WorktreePaths(root: twin).stateFile))
        let twinState = WorktreeState(id: "twin-id", name: "main", project: "Sample App", projectRoot: twin, path: twin,
                                      branch: "main", xcode: nil, devices: [:], status: .ready, createdAt: Date())
        let registry = Registry(paths: GlobalPaths(base: project.home))
        try await registry.upsert(RegistryEntry(twinState))
        #expect(try registry.entries().map(\.projectRoot) == [project.root, twin].sorted())
        let clone = sims.add(name: "xcd · Sample App · main · ipad",
                             dataPath: try agedDevice(project.base + "/old-device", seconds: 3600))

        let report = await doctor(project).run(fix: true, checks: [OrphanedClonesCheck()], from: nil)
        #expect(report.problems.isEmpty)
        #expect(sims.devices.contains { $0.udid == clone })

        try await registry.remove(id: "twin-id")                                // with only ours, it is an orphan
        let alone = await doctor(project).run(fix: false, checks: [OrphanedClonesCheck()], from: nil)
        #expect(alone.problems.map(\.subject) == [clone])
    }

    /// Ownership is by name prefix, so " · " inside a device key or project name doesn't
    /// make a young clone of a registered worktree look ownerless.
    @Test func namesContainingTheSeparatorKeepTheirOwner() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        let odd = project.base + "/Odd · Name"
        try FileManager.default.createDirectory(atPath: odd, withIntermediateDirectories: true)
        let state = WorktreeState(id: "odd-id", name: "main", project: "Odd · Name", projectRoot: odd, path: odd,
                                  branch: "main", xcode: nil, devices: [:], status: .ready, createdAt: Date())
        try WorktreeStateStore.save(state, WorktreePaths(root: odd))
        try await Registry(paths: GlobalPaths(base: project.home)).upsert(RegistryEntry(state))
        let key = sims.add(name: "xcd · Sample App · main · iPhone · Pro",
                           dataPath: try agedDevice(project.base + "/young-1", seconds: 5))
        let name = sims.add(name: "xcd · Odd · Name · main · iphone",
                            dataPath: try agedDevice(project.base + "/young-2", seconds: 5))

        let report = await doctor(project).run(fix: true, checks: [OrphanedClonesCheck()], from: nil)
        #expect(report.problems.isEmpty)
        #expect(Set(sims.devices.map(\.udid)).isSuperset(of: [key, name]))
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

    /// An unrecorded clone of a worktree that exists is deleted only while it is shut down. A booted
    /// one is in use (an agent may have booted it by hand), so it is reported with what to do, and left alone.
    @Test func anUnrecordedCloneOfALiveWorktreeIsDeletedOnlyWhenShutDown() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        let idle = sims.add(name: "xcd · Sample App · main · ipad",
                            dataPath: try agedDevice(project.base + "/old-1", seconds: 3600))
        let inUse = sims.add(name: "xcd · Sample App · main · iphone", state: "Booted",
                             dataPath: try agedDevice(project.base + "/old-2", seconds: 3600))
        let report = await doctor(project).run(fix: true, checks: [OrphanedClonesCheck()], from: nil, includeDisk: false)
        #expect(report.problems.first { $0.subject == idle }?.fixed == true)
        let booted = try #require(report.problems.first { $0.subject == inUse })
        #expect(booted.message == "xcd · Sample App · main · iphone (\(inUse)) is orphaned: Sample App/main doesn't record it, and it is Booted")
        #expect(booted.action == nil && !booted.fixed)
        #expect(booted.next == "if nothing is using it, delete it with `xcrun simctl shutdown \(inUse); xcrun simctl delete \(inUse)`")
        #expect(!sims.devices.contains { $0.udid == idle })
        #expect(sims.devices.first { $0.udid == inUse }?.state == "Booted")
        #expect(!fake.calls.contains { $0.argv == ["xcrun", "simctl", "shutdown", inUse] })

        // Booted between detect and fix: left alone too.
        let late = sims.add(name: "xcd · Sample App · main · watch",
                            dataPath: try agedDevice(project.base + "/old-3", seconds: 3600))
        let env = await doctor(project).environment(from: nil, fixing: true)
        let problem = try #require(await OrphanedClonesCheck().detect(env).first { $0.subject == late })
        #expect(problem.action == .deleteSimulator)
        sims.setState("Booted", udid: late)
        await #expect(throws: DoctorLeftAlone.self) { try await OrphanedClonesCheck().fix(problem, env) }
        #expect(sims.devices.first { $0.udid == late }?.state == "Booted")
    }

    /// An old, unrecorded clone of a worktree another xcd is creating or removing is that xcd's.
    @Test(.timeLimit(.minutes(1))) func aBusyWorktreesUnrecordedCloneIsNotOrphaned() async throws {
        let (project, sims, worktrees, main) = try await setup()
        defer { project.remove() }
        _ = try await worktrees.create(name: "feat", in: main)
        let clone = sims.add(name: "xcd · Sample App · feat · iphone",
                             dataPath: try agedDevice(project.base + "/old-device", seconds: 3600))
        let holder = try await holdLock(worktrees.lockPath(projectRoot: project.root, worktree: "feat"))
        let report = await doctor(project).run(fix: true, checks: [OrphanedClonesCheck()], from: nil, includeDisk: false)
        holder.cancel()
        _ = await holder.result
        #expect(report.problems.isEmpty)
        #expect(sims.devices.contains { $0.udid == clone })
        #expect(await doctor(project).run(fix: false, checks: [OrphanedClonesCheck()], from: nil).problems.map(\.subject) == [clone])
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

    /// A checkout is gone only when lstat says so and nothing stands in the way of looking.
    @Test func aCheckoutIsMissingOnlyWhenItIsReallyGone() throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        #expect(CheckoutPresence.of(project.root) == .present)
        #expect(CheckoutPresence.of(project.base + "/gone/feat") == .missing)                  // ENOENT, readable ancestor
        #expect(CheckoutPresence.of("/Volumes/xcd-unmounted-\(UUID().uuidString)/App.worktrees/feat") == .unreachable)
        // A folder that can be searched but not read, and one that can't be searched at all.
        let locked = project.base + "/locked"
        try FileManager.default.createDirectory(atPath: locked + "/inner", withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        try FileManager.default.setAttributes([.posixPermissions: 0o100], ofItemAtPath: locked)
        #expect(CheckoutPresence.of(locked + "/feat") == .unreachable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        #expect(CheckoutPresence.of(locked + "/inner") == .unreachable)
    }

    /// A worktree on a volume that isn't mounted is reported, never dropped, and its clones are spared.
    @Test func aWorktreeOnAnUnmountedVolumeIsOnlyReported() async throws {
        let (project, sims, worktrees, _) = try await setup()
        defer { project.remove() }
        let path = "/Volumes/xcd-unmounted-\(UUID().uuidString)/Sample App.worktrees/feat"
        let state = WorktreeState(id: "feat-id", name: "feat", project: "Sample App", projectRoot: project.root, path: path,
                                  branch: "feat", xcode: nil, devices: [:], status: .ready, createdAt: Date())
        try await Registry(paths: GlobalPaths(base: project.home)).upsert(RegistryEntry(state))
        let clone = sims.add(name: "xcd · Sample App · feat · iphone",
                             dataPath: try agedDevice(project.base + "/old-device", seconds: 3600))

        let report = await doctor(project).run(fix: true, checks: DoctorService.pruneChecks, from: nil, includeDisk: false)
        let problem = try #require(report.problems.first)
        #expect(report.problems.count == 1 && problem.check == "missing-worktrees")
        #expect(problem.message == "Sample App/feat: \(path) can't be reached")
        #expect(problem.next == "it may be on a volume that isn't mounted, or in a folder xcd may not look into; mount it or fix the permissions, then run `xcd doctor` again")
        #expect(problem.action == nil && !problem.fixed)
        #expect(try worktrees.list(projectRoot: project.root).map(\.name) == ["feat", "main"])
        #expect(sims.devices.contains { $0.udid == clone })
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
        // 5s to call it stuck, then up to 4 minutes for a cold boot to finish before shutting it down.
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

    /// The fix outwaits the longest a boot may take (`simctl boot`'s own timeout), with margin.
    @Test func theSettleWaitOutlastsABoot() {
        #expect(StuckClonesCheck.settleTimeout >= .seconds(240))
        #expect(StuckClonesCheck.settleTimeout >= SimctlClient.bootTimeout + .seconds(60))
    }

    /// A clone of a worktree another xcd is creating or removing is that xcd's to settle.
    @Test(.timeLimit(.minutes(1))) func aBusyWorktreesBootingCloneIsLeftAlone() async throws {
        let (project, sims, worktrees, main) = try await setup()
        defer { project.remove() }
        var (feat, _) = try await worktrees.create(name: "feat", in: main)
        let booting = sims.add(name: "xcd · Sample App · feat · iphone", state: "Booting")
        let broken = sims.add(name: "xcd · Sample App · feat · watch", isAvailable: false)
        feat.devices["iphone"] = ProvisionedDevice(udid: booting, deviceType: "P", deviceTypeIdentifier: "p", runtime: "iOS", runtimeIdentifier: "r")
        feat.devices["watch"] = ProvisionedDevice(udid: broken, deviceType: "W", deviceTypeIdentifier: "w", runtime: "watchOS", runtimeIdentifier: "r")
        try WorktreeStateStore.save(feat, WorktreePaths(root: feat.path))

        let holder = try await holdLock(worktrees.lockPath(projectRoot: project.root, worktree: "feat"))
        let report = await doctor(project).run(fix: true, checks: [StuckClonesCheck()], from: nil, includeDisk: false)
        holder.cancel()
        _ = await holder.result
        #expect(report.problems.isEmpty && report.failure == nil)
        #expect(report.checks.first?.inProgress.sorted() == [
            "xcd · Sample App · feat · iphone (\(booting)) is Booting while Sample App/feat is being created or removed by another xcd; left alone",
            "xcd · Sample App · feat · watch (\(broken)) is unavailable while Sample App/feat is being created or removed by another xcd; left alone",
        ])
        #expect(sims.devices.first { $0.udid == booting }?.state == "Booting")
        #expect(sims.devices.contains { $0.udid == broken })
        #expect(!fake.calls.contains { $0.argv.starts(with: ["xcrun", "simctl", "shutdown"]) || $0.argv.starts(with: ["xcrun", "simctl", "delete"]) })
    }

    /// Without --fix, a clone that is still booting is reported as in progress, not as a problem.
    @Test func aPlainDoctorListsABootingCloneAsInProgress() async throws {
        var (project, sims, _, main) = try await setup()
        defer { project.remove() }
        let booting = sims.add(name: "xcd · Sample App · main · iphone", state: "Booting")
        let stuck = sims.add(name: "xcd · Sample App · main · ipad", state: "Shutting Down")
        try record(booting, as: "iphone", in: &main)
        try record(stuck, as: "ipad", in: &main)
        let report = await doctor(project).run(fix: false, checks: [StuckClonesCheck()], from: nil, includeDisk: false)
        #expect(report.problems.map(\.message) == ["xcd · Sample App · main · ipad (\(stuck)) is stuck in Shutting Down"])
        #expect(report.checks.first?.inProgress == [
            "xcd · Sample App · main · iphone (\(booting)) is Booting, which can take a few minutes; `--fix` shuts it down if it is still booting after 4 minutes",
        ])
        #expect(report.text.contains("\nbusy     stuck-clones  xcd · Sample App · main · iphone (\(booting)) is Booting"))
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

    @Test func staleInitScratchIsReportedWithItsSizeAndDeletedOnlyByFix() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let now = Date()
        let cache = GlobalPaths(base: project.home).cacheDirectory
        let fm = FileManager.default
        func folder(_ name: String, age: TimeInterval) throws -> String {
            let path = cache + "/" + name
            try fm.createDirectory(atPath: path + "/.xcdev", withIntermediateDirectories: true)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: path)
            return path
        }
        let stale = [try folder("init-" + UUID().uuidString, age: 2 * 3600), try folder("init-" + UUID().uuidString, age: 26 * 3600)]
        let recent = try folder("init-" + UUID().uuidString, age: 10 * 60)
        let others = [try folder("init-notes", age: 9 * 3600), try folder("packages", age: 9 * 3600)]
        fake.stub(["du", "-sk"]) { inv in
            ProcessOutput(stdout: inv.arguments.dropFirst().map { "614400\t\($0)\n" }.joined())         // 600 MB each
        }
        let service = DoctorService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                                    discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []), now: { now })

        let report = await service.run(fix: false, checks: [InitScratchCheck()], from: nil, includeDisk: false)
        let problem = try #require(report.problems.first)
        #expect(report.problems.count == 1 && problem.action == .deleteScratch && !problem.fixed)
        #expect(problem.message == "2 scratch folders of interrupted `xcd init` runs, older than an hour, use 1.2GB in \(cache)")
        #expect((stale + [recent] + others).allSatisfy { fm.fileExists(atPath: $0) })   // doctor alone changes nothing
        #expect(fake.calls.filter { $0.argv.first == "du" }.map { Set($0.arguments.dropFirst()) } == [Set(stale)])

        let fixed = await service.run(fix: true, checks: [InitScratchCheck()], from: nil, includeDisk: false)
        #expect(fixed.problems.count == 1 && fixed.problems[0].fixed)
        #expect(stale.allSatisfy { !fm.fileExists(atPath: $0) })
        #expect(([recent] + others).allSatisfy { fm.fileExists(atPath: $0) })
        #expect(await service.run(fix: false, checks: [InitScratchCheck()], from: nil, includeDisk: false).problems.isEmpty)
    }

    @Test func theScratchFixTriesEveryFolderAndNamesTheOnesItCouldNotDelete() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let now = Date()
        let cache = GlobalPaths(base: project.home).cacheDirectory
        let fm = FileManager.default
        var stale: [String] = []
        for _ in 0..<3 {
            let path = cache + "/init-" + UUID().uuidString
            try fm.createDirectory(atPath: path + "/.xcdev", withIntermediateDirectories: true)
            fm.createFile(atPath: path + "/.xcdev/file", contents: Data())
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: path)
            stale.append(path)
        }
        let stuck = stale.sorted()[0]                                          // the first one tried
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stuck + "/.xcdev")
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stuck + "/.xcdev") }
        fake.stub(["du", "-sk"], stdout: "")
        let service = DoctorService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                                    discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []), now: { now })
        let report = await service.run(fix: true, checks: [InitScratchCheck()], from: nil, includeDisk: false)
        let problem = try #require(report.problems.first)
        #expect(!problem.fixed && problem.fixError?.hasPrefix("could not delete 1 of the scratch folders; delete them by hand: \(stuck): ") == true)
        #expect(stale.filter { fm.fileExists(atPath: $0) } == [stuck])
    }

    /// Earlier versions of xcd kept each project's Swift packages for `init` in `<home>/cache/packages/<key>`, locked
    /// by `<key>.lock`. Nothing uses them now, so all of them are reclaimable, except one whose lock an older xcd holds.
    @Test func packageCachesFromEarlierVersionsAreDeletedOnlyByFix() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let packages = GlobalPaths(base: project.home).cacheDirectory + "/packages"
        let fm = FileManager.default
        func cache(_ key: String, root: String? = nil) throws -> String {
            let directory = packages + "/" + key
            try fm.createDirectory(atPath: directory + "/SourcePackages/checkouts", withIntermediateDirectories: true)
            if let root { try root.write(toFile: directory + "/root", atomically: true, encoding: .utf8) }
            fm.createFile(atPath: directory + ".lock", contents: Data())
            return directory
        }
        let gone = try cache("Deleted-App-1f2e3d4c5b6a7980", root: project.base + "/Deleted App")
        let live = try cache("Sample-App-0123456789abcdef", root: project.root)
        let unrecorded = try cache("Who-Knows-fedcba9876543210")
        let busy = try cache("Busy-0011223344556677")
        fake.stub(["du", "-sk"]) { inv in
            ProcessOutput(stdout: inv.arguments.dropFirst().map { "1258291\t\($0)\n" }.joined())       // 1.2 GB each
        }
        let release = Counter()
        let holder = Task {
            try await FileLock.withLock(at: busy + ".lock") {
                while release.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
            }
        }
        defer { release.increment() }
        while !FileLock.isHeld(at: busy + ".lock") { try await Task.sleep(for: .milliseconds(5)) }

        let report = await doctor(project).run(fix: false, checks: [PackageCacheCheck()], from: nil, includeDisk: false)
        let check = try #require(report.checks.first)
        #expect(check.problems.map(\.subject) == [gone, live, unrecorded].sorted())
        let problem = try #require(check.problems.first { $0.subject == live })
        #expect(problem.action == .deletePackageCache && problem.fix == "delete it")
        #expect(problem.message == "the Swift package cache \(live) (1.2GB) is left over from an earlier version of xcd; "
                + "`xcd init` no longer keeps one")
        #expect(check.inProgress == ["the Swift package cache \(busy) is in use by an earlier version's `xcd init`; left alone"])
        #expect([gone, live, unrecorded, busy].allSatisfy { fm.fileExists(atPath: $0 + "/SourcePackages") })   // doctor alone deletes nothing

        let fixed = await doctor(project).run(fix: true, checks: [PackageCacheCheck()], from: nil, includeDisk: false)
        #expect(fixed.problems.count == 3 && fixed.problems.allSatisfy(\.fixed))
        #expect([gone, live, unrecorded].allSatisfy { !fm.fileExists(atPath: $0) && !fm.fileExists(atPath: $0 + ".lock") })
        #expect(fm.fileExists(atPath: busy + "/SourcePackages"))
        // Locked after doctor looked: the fix takes the lock without waiting, and leaves the cache alone.
        let late = DoctorProblem(check: "package-caches", message: "", action: .deletePackageCache, subject: busy)
        let env = await doctor(project).environment(from: nil)
        await #expect(throws: DoctorLeftAlone.self) { try await PackageCacheCheck().fix(late, env) }
        #expect(fm.fileExists(atPath: busy + "/SourcePackages"))
        release.increment()
        try await holder.value
    }

    @Test func pruneOnlyLooksForOrphans() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        sims.add(name: "xcd-template · iPhone 18 Pro · iOS 27.0", state: "Booted")
        let orphan = sims.add(name: "xcd · Sample App · gone · iphone")
        let report = await doctor(project).run(fix: true, checks: DoctorService.pruneChecks, from: nil, includeDisk: false)
        #expect(report.checks.map(\.id) == ["missing-worktrees", "orphaned-clones"])
        #expect(report.problems.count == 1 && report.problems[0].subject == orphan && report.problems[0].fixed)
        #expect(report.disk == nil)
    }

    @Test func projectSetupProblemsSayWhatToDo() async throws {
        let apps = FileManager.default.temporaryDirectory.appendingPathComponent("xcd apps \(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: apps) }
        try XcodeTests.makeFakeXcode(at: apps + "/Xcode.app", version: "27.0", build: "27A266a")
        fake.stub(["mdfind"], stdout: "")
        fake.stub(["xcode-select", "-p"], stdout: apps + "/Xcode.app/Contents/Developer\n")
        var (project, _, _, main) = try await setup(config: """
        version: 1
        project: App.xcodeproj
        xcode: "26.4"
        defaultDevice: iphone
        devices:
          iphone: { type: "iPhone 99" }
          mac: { platform: macOS }
        """)
        defer { project.remove() }
        main.state.xcode = XcodeInstall(path: apps + "/Xcode-26.4.app", version: "26.4", build: "x")
        try WorktreeStateStore.save(main.state, main.paths)
        let discovery = XcodeDiscovery(runner: fake, applicationsDirectories: [apps])

        let report = await doctor(project, discovery: discovery).run(fix: false, from: project.root)
        let found = report.problems.filter { $0.check == "project" }
        #expect(found.map { $0.message.components(separatedBy: " (").last ?? "" }.contains("xcode_missing)"))
        #expect(found.contains { $0.message.hasPrefix("worktree 'main' is pinned to Xcode 26.4 (x)") && $0.action == .unpinXcode })
        #expect(found.contains { $0.message.hasPrefix("device type 'iPhone 99' (devices.iphone.type) is not available") })
        // Each one says what to do, by hand (`next:`) or with --fix.
        let xcode = try #require(found.first { $0.message.hasPrefix("Xcode 26.4 is not installed") })
        #expect(xcode.next == "set `xcode:` in .xcdev.yml to an installed version, e.g. \"27.0\"")
        let device = try #require(found.first { $0.message.hasPrefix("device type 'iPhone 99'") })
        #expect(device.next?.hasPrefix("set devices.iphone.type to one of: ") == true
                || device.next == "run `xcrun simctl list devicetypes` and set devices.iphone.type")
        let pinned = try #require(found.first { $0.action == .unpinXcode })
        #expect(pinned.fix == "unpin it, so the next command resolves `xcode:` again")
        #expect(report.failure?.next == "run `xcd doctor --fix` to fix 1 of them; the others say what to do")
        #expect(report.text.contains("problem  project  Xcode 26.4 is not installed (xcode_missing)  next: set `xcode:`"))
        #expect(report.text.contains("(--fix: unpin it, so the next command resolves `xcode:` again)"))
        #expect(try WorktreeStateStore.load(main.paths)?.xcode != nil)          // reported only, without --fix

        _ = await doctor(project, discovery: discovery).run(fix: true, checks: [ProjectCheck()], from: project.root)
        #expect(try WorktreeStateStore.load(main.paths)?.xcode == nil)
    }

    /// Re-pinned to an installed Xcode between detect and fix, the worktree keeps its pin.
    @Test func aWorktreeRepinnedMeanwhileIsNotUnpinned() async throws {
        var (project, _, _, main) = try await setup()
        defer { project.remove() }
        let installed = project.base + "/Xcode.app"
        try FileManager.default.createDirectory(atPath: installed, withIntermediateDirectories: true)
        main.state.xcode = XcodeInstall(path: project.base + "/Xcode-26.4.app", version: "26.4", build: "x")
        try WorktreeStateStore.save(main.state, main.paths)
        let env = await doctor(project).environment(from: project.root, fixing: true)
        let problem = try #require(await ProjectCheck().detect(env).first { $0.action == .unpinXcode })

        main.state.xcode = XcodeInstall(path: installed, version: "27.0", build: "27A266a")
        try WorktreeStateStore.save(main.state, main.paths)
        await #expect(throws: DoctorLeftAlone.self) { try await ProjectCheck().fix(problem, env) }
        #expect(try WorktreeStateStore.load(main.paths)?.xcode?.path == installed)
    }

    @Test func anInvalidConfigIsAProblemNotAnError() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        try project.write("version: 1\nproject: App.xcodeproj\ndevics: {}\n", to: ".xcdev.yml")
        let report = await doctor(project).run(fix: false, checks: [ProjectCheck()], from: project.root)
        #expect(report.problems.map(\.message) == [".xcdev.yml is invalid (1 problem): devics: unknown key (did you mean 'devices'?) (config_invalid)"])
        #expect(report.problems.map(\.next) == ["fix .xcdev.yml, then run `xcd config show`"])
        #expect(report.failure?.next == "fix .xcdev.yml, then run `xcd config show`")
    }

    @Test func outsideAProjectTheProjectCheckIsSkipped() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let report = await doctor(project).run(fix: false, checks: [ProjectCheck()], from: project.base)
        #expect(report.checks.isEmpty && report.failure == nil)
    }

    /// A plain `doctor` in a project xcd never opened writes nothing (no .xcdev/, registry,
    /// or worktree state) and runs no command that changes anything. The SDK cache is the one exception.
    @Test func doctorWithoutFixWritesNothing() async throws {
        let project = try TempProject.make(config: """
        version: 1
        project: App.xcodeproj
        xcode: "27.0"
        defaultDevice: iphone
        devices:
          iphone: { type: "iPhone 18 Pro" }
        """)
        defer { project.remove() }
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        let apps = project.base + "/apps"
        try XcodeTests.makeFakeXcode(at: apps + "/Xcode.app", version: "27.0", build: "27A266a")
        fake.stub(["mdfind"], stdout: "")
        fake.stub(["xcode-select", "-p"], stdout: apps + "/Xcode.app/Contents/Developer\n")
        let runner = ArgvRecorder(RoutingRunner(fake: fake))
        let service = DoctorService(runner: runner, globalPaths: GlobalPaths(base: project.home),
                                    discovery: XcodeDiscovery(runner: runner, applicationsDirectories: [apps]))
        let before = try Self.snapshot(project.base)

        #expect(try Registry(paths: GlobalPaths(base: project.home)).entries().isEmpty)    // reading a missing registry
        #expect(try Self.snapshot(project.base) == before)
        let report = await service.run(fix: false, from: project.root)

        #expect(report.checks.map(\.id).last == "project" && report.problems.isEmpty)
        let cache = GlobalPaths(base: project.home).cacheDirectory
        let after = try Self.snapshot(project.base)
        #expect(before.filter { after[$0.key] != $0.value }.isEmpty)               // nothing changed or removed
        let added = Set(after.keys).subtracting(before.keys)
        #expect(added.contains(project.home) && added.contains(cache))             // the SDK cache, and only it
        let cached = added.subtracting([project.home, cache])
        #expect(!cached.isEmpty && cached.allSatisfy {
            $0.hasPrefix(cache + "/sdks-") && $0.hasSuffix(".json") && !$0.dropFirst(cache.count + 1).contains("/")
        })
        #expect(!FileManager.default.fileExists(atPath: project.root + "/.xcdev"))
        #expect(!FileManager.default.fileExists(atPath: GlobalPaths(base: project.home).registryFile))

        let readOnly: [[String]] = [["git", "rev-parse"], ["xcrun", "simctl", "list"], ["mdfind"], ["xcode-select", "-p"],
                                    ["xcrun", "xcodebuild", "-showsdks"], ["du"]]
        #expect(!runner.calls.isEmpty)
        let commands = runner.calls.map { $0.starts(with: ["git", "-C"]) ? ["git"] + $0.dropFirst(3) : $0 }
        #expect(commands.filter { argv in !readOnly.contains { argv.starts(with: $0) } } == [])
    }

    /// Every file and folder under `root`: a file's contents, or "dir" for a folder.
    static func snapshot(_ root: String) throws -> [String: Data] {
        var tree: [String: Data] = [:]
        let fm = FileManager.default
        guard let paths = fm.subpaths(atPath: root) else { return tree }
        for relative in paths {
            let path = root + "/" + relative
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            tree[path] = isDirectory.boolValue ? Data("dir".utf8) : try Data(contentsOf: URL(fileURLWithPath: path))
        }
        return tree
    }
}

/// Records every command's argv, git included, then runs it on `inner`.
private final class ArgvRecorder: ProcessRunning {
    let inner: any ProcessRunning
    private let recorded = Mutex<[[String]]>([])

    init(_ inner: any ProcessRunning) { self.inner = inner }

    var calls: [[String]] { recorded.withLock { $0 } }

    func run(_ invocation: Invocation) async throws -> ProcessOutput {
        recorded.withLock { $0.append(invocation.argv) }
        return try await inner.run(invocation)
    }
}
