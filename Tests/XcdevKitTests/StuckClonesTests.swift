import Foundation
import Synchronization
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd doctor`'s stuck-clones check: recorded clones that are unavailable or stuck booting or shutting down.
@Suite struct StuckClonesTests: DoctorFixture {
    let fake = FakeProcessRunner()

    @Test func stuckAndUnavailableClonesAreShutDownOrRecloned() async throws {
        var (project, sims, _, main) = try await setup()
        defer { project.remove() }
        let stuck = sims.add(name: "xcd · Sample App · main · iphone", state: "Booting")
        let broken = sims.add(name: "xcd · Sample App · main · watch", isAvailable: false)
        try record(stuck, as: "iphone", in: &main)
        try record(broken, as: "watch", in: &main)
        let slept = Mutex(Duration.zero)

        let report = await doctor(project, sleep: { d in slept.withLock { $0 += d } }).run(fix: true, from: project.root)
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

        let report = await service.run(fix: true, checks: [StuckClonesCheck()], from: project.root, includeDisk: false)
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
    @Test(.timeLimit(.minutes(5))) func aBusyWorktreesBootingCloneIsLeftAlone() async throws {
        let (project, sims, worktrees, main) = try await setup()
        defer { project.remove() }
        var (feat, _) = try await worktrees.create(name: "feat", in: main)
        let booting = sims.add(name: "xcd · Sample App · feat · iphone", state: "Booting")
        let broken = sims.add(name: "xcd · Sample App · feat · watch", isAvailable: false)
        feat.devices["iphone"] = ProvisionedDevice(udid: booting, deviceType: "P", deviceTypeIdentifier: "p", runtime: "iOS", runtimeIdentifier: "r")
        feat.devices["watch"] = ProvisionedDevice(udid: broken, deviceType: "W", deviceTypeIdentifier: "w", runtime: "watchOS", runtimeIdentifier: "r")
        try WorktreeStateStore.save(feat, WorktreePaths(root: feat.path))

        let holder = try await holdLock(worktrees.lockPath(projectRoot: project.root, worktree: "feat"))
        let report = await doctor(project).run(fix: true, checks: [StuckClonesCheck()], from: project.root, includeDisk: false)
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
        let report = await doctor(project).run(fix: true, checks: [StuckClonesCheck()], from: project.root)
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
}
