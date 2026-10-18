import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd doctor`'s orphaned-clones check: which clones nothing owns, and which of them `--fix` may delete.
@Suite struct OrphanedClonesTests: DoctorFixture {
    let fake = FakeProcessRunner()

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
        let report = await doctor(project).run(fix: false, checks: [OrphanedClonesCheck()], from: project.root)
        let orphans = report.problems.filter { $0.check == "orphaned-clones" }
        #expect(orphans.compactMap(\.subject).sorted() == [gone, other].sorted())
        #expect(orphans.first { $0.subject == gone }?.message == "xcd · Sample App · deleted · iphone (\(gone)) is orphaned: its worktree no longer exists")
        #expect(report.failure?.code == .doctorProblems)
        #expect(report.failure?.next == "run `xcd doctor --fix` to fix 1 of them")
        #expect(report.elsewhere.map(\.subject) == [other])
        #expect(sims.devices == before)                                           // nothing changed without --fix

        // `other` is from a project this registry doesn't know: maybe another XCDEV_HOME's, so it is only reported.
        let fixed = await doctor(project).run(fix: true, checks: [OrphanedClonesCheck()], from: project.root)
        #expect(fixed.problems.filter(\.fixed).map(\.subject) == [gone])
        #expect(fixed.remaining.isEmpty && fixed.elsewhere.map(\.subject) == [other] && fixed.elsewhere[0].fixError == nil)
        #expect(fixed.failure == nil)
        #expect(Set(sims.devices.map(\.udid)).isSuperset(of: [owned, inFlight, other]))
        #expect(!sims.devices.contains { $0.udid == gone })
    }

    /// With no registry.json (a fresh or different XCDEV_HOME), no clone has a known owner,
    /// so none is deleted; each is reported with the command to delete it by hand.
    @Test func aMissingRegistryNeverDeletesClones() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        try FileManager.default.removeItem(atPath: GlobalPaths(base: project.home).registryFile)
        let clone = sims.add(name: "xcd · Sample App · main · iphone",
                             dataPath: try agedDevice(project.base + "/old-device", seconds: 3600))

        let report = await doctor(project).run(fix: true, from: project.root)
        #expect(sims.devices.contains { $0.udid == clone })
        let problem = try #require(report.problems.first { $0.check == "orphaned-clones" })
        #expect(problem.message == "xcd · Sample App · main · iphone (\(clone)) is orphaned: no worktree in this registry is from its project")
        #expect(problem.next == "it may belong to another xcd state folder (XCDEV_HOME); ask the user before deleting it: `xcrun simctl shutdown \(clone); xcrun simctl delete \(clone)`")
        #expect(problem.action == nil && !problem.fixed && problem.fixError == nil)
        #expect(problem.elsewhere == true && !report.remaining.contains { $0.subject == problem.subject })
        #expect(!fake.calls.contains { $0.argv.starts(with: ["xcrun", "simctl", "delete"]) })
    }

    /// A clone of a known project whose worktree is no longer registered is deleted, however old it is.
    @Test func aCloneOfAKnownProjectsGoneWorktreeIsDeleted() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        let clone = sims.add(name: "xcd · Sample App · gone · iphone",
                             dataPath: try agedDevice(project.base + "/old-device", seconds: 601))
        let report = await doctor(project).run(fix: true, checks: [OrphanedClonesCheck()], from: project.root)
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

        let report = await doctor(project).run(fix: true, checks: [OrphanedClonesCheck()], from: project.root)
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

        let report = await doctor(project).run(fix: true, checks: [OrphanedClonesCheck()], from: project.root)
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
        let report = await doctor(project).run(fix: true, checks: [OrphanedClonesCheck()], from: project.root, includeDisk: false)
        #expect(report.problems.first { $0.subject == idle }?.fixed == true)
        let booted = try #require(report.problems.first { $0.subject == inUse })
        #expect(booted.message == "xcd · Sample App · main · iphone (\(inUse)) is orphaned: Sample App/main doesn't record it, and it is Booted")
        #expect(booted.action == nil && !booted.fixed)
        #expect(booted.next == "ask the user before deleting it: `xcrun simctl shutdown \(inUse); xcrun simctl delete \(inUse)`")
        #expect(!sims.devices.contains { $0.udid == idle })
        #expect(sims.devices.first { $0.udid == inUse }?.state == "Booted")
        #expect(!fake.calls.contains { $0.argv == ["xcrun", "simctl", "shutdown", inUse] })

        // Booted between detect and fix: left alone too.
        let late = sims.add(name: "xcd · Sample App · main · watch",
                            dataPath: try agedDevice(project.base + "/old-3", seconds: 3600))
        let env = await doctor(project).environment(from: nil, fixing: true)
        let problem = try #require(OrphanedClonesCheck().detect(env).first { $0.subject == late })
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
        let report = await doctor(project).run(fix: true, checks: [OrphanedClonesCheck()], from: project.root, includeDisk: false)
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

        let report = await doctor(project).run(fix: true, from: project.root)
        #expect(sims.devices.contains { $0.udid == clone })
        #expect(report.problems.filter { $0.check == "orphaned-clones" }.isEmpty)
        let unreadable = try #require(report.problems.first { $0.check == "missing-worktrees" })
        #expect(unreadable.message.hasSuffix("registry.json is corrupt") && unreadable.action == nil && unreadable.next != nil)
        #expect(report.failure?.code == .doctorProblems)
    }
}
