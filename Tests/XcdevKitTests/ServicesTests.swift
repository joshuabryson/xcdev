import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct ServicesTests {
    @Test func servicesShareOneDetachedLauncher() {
        let detached = FakeDetachedProcesses()
        let services = Services(runner: FakeProcessRunner(), globalPaths: GlobalPaths(base: "/h"), currentDirectory: "/cwd",
                                environment: [:], detached: detached)
        #expect(services.media.detached as? FakeDetachedProcesses === detached)
        #expect(services.worktrees.detached as? FakeDetachedProcesses === detached)
        #expect(services.doctor.detached as? FakeDetachedProcesses === detached)
        #expect(services.media.currentDirectory == "/cwd")
    }

    /// The crash report is waited for 10 s, times `XCD_TIMEOUT_SCALE` from the environment the services are given.
    @Test func theCrashReportWaitFollowsTheTimeoutScale() {
        let plain = Services(runner: FakeProcessRunner(), globalPaths: GlobalPaths(base: "/h"), currentDirectory: "/cwd", environment: [:])
        let slow = Services(runner: FakeProcessRunner(), globalPaths: GlobalPaths(base: "/h"), currentDirectory: "/cwd",
                            environment: ["XCD_TIMEOUT_SCALE": "4"])
        #expect(plain.crashWatcher.reportWait == .seconds(10) && slow.crashWatcher.reportWait == .seconds(40))
    }

    /// Every clone a command boots starts its watchdog as this xcd, on the shared launcher, under this home.
    @Test func theProvisionerStartsIdleSessions() throws {
        let detached = FakeDetachedProcesses()
        var services = Services(runner: FakeProcessRunner(), globalPaths: GlobalPaths(base: "/h"), currentDirectory: "/cwd",
                                environment: [:], detached: detached)
        services.xcdExecutable = "/built/xcd"
        let sessions = try #require(services.provisioner.sessions)
        #expect(sessions.watchdogs.detached as? FakeDetachedProcesses === detached)
        #expect(sessions.executable == "/built/xcd")
        #expect(sessions.leases.globalPaths == GlobalPaths(base: "/h") && sessions.leases.holds === LeaseHolds.shared)
        #expect(services.runners.provisioner.sessions != nil && services.builds.provisioner.sessions != nil)
    }

    /// `xcd lint` reads paths from where it is run, and looks for the linter in this process's PATH first. Its
    /// scratch folders are registered with the handler Ctrl-C fires, or they would be left behind.
    @Test func lintGetsTheCurrentDirectoryThePathAndTheOutputFormat() {
        let services = Services(runner: FakeProcessRunner(), globalPaths: GlobalPaths(base: "/h"), currentDirectory: "/cwd",
                                environment: ["PATH": "/custom/bin:/usr/bin"], output: .json, interrupts: Interrupts())
        let host = services.lint.host
        #expect(host.currentDirectory == "/cwd" && host.output == .json)
        #expect(host.interrupts === services.interrupts)
        #expect(host.locator.folders == ["/custom/bin", "/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"])
        #expect(services.setup.locator.folders == host.locator.folders)                // `init` says whether the linter is installed
        #expect(host.targets.currentDirectory == "/cwd")
    }

    /// `xcd format` runs with what `xcd lint` runs with, so its copies for a formatter's standard input are removed
    /// by the same handler.
    @Test func formatIsGivenWhatLintIsGiven() {
        let services = Services(runner: FakeProcessRunner(), globalPaths: GlobalPaths(base: "/h"), currentDirectory: "/cwd",
                                environment: ["PATH": "/custom/bin:/usr/bin"], output: .json, interrupts: Interrupts())
        let host = services.format.host
        #expect(host.currentDirectory == "/cwd" && host.output == .json && host.interrupts === services.interrupts)
        #expect(host.locator.folders == services.lint.host.locator.folders && services.format.atOnce == 8)
    }

    @Test func uiServicesShareTheLauncherAndTransport() {
        let detached = FakeDetachedProcesses()
        let transport = FakeRunnerTransport()
        let services = Services(runner: FakeProcessRunner(), globalPaths: GlobalPaths(base: "/h"), currentDirectory: "/cwd",
                                environment: [:], detached: detached, runnerTransport: transport)
        #expect(services.runners.detached as? FakeDetachedProcesses === detached)
        #expect(services.ui.client.transport as? FakeRunnerTransport === transport)
        #expect(services.runners.client.transport as? FakeRunnerTransport === transport)
        #expect(services.ui.supervisor.client.transport as? FakeRunnerTransport === transport)
        #expect(services.runnerBuilder.globalPaths == GlobalPaths(base: "/h"))
    }

    /// A real checkout with one device in its state and a lease for it, saved at `t0`.
    func leasedCheckout(udid: String, t0: Date) async throws -> (project: TempProject, services: Services, leases: DeviceLeases) {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        let services = Services(runner: RoutingRunner(fake: FakeProcessRunner()), globalPaths: GlobalPaths(base: project.home),
                                currentDirectory: project.root, environment: [:])
        var state = try await services.open(worktree: nil, renewsLeases: false).state
        state.devices["iphone"] = ProvisionedDevice(udid: udid, deviceType: "t", deviceTypeIdentifier: "t", runtime: "r",
                                                    runtimeIdentifier: "r")
        try WorktreeStateStore.save(state, WorktreePaths(root: project.root))
        let leases = DeviceLeases(globalPaths: services.globalPaths)
        try leases.save(.sample(udid: udid, renewedAt: t0, idle: 600, root: project.root))
        return (project, services, leases)
    }

    @Test func openRenewsAndHoldsTheWorktreesLeases() async throws {
        let t0 = Date(timeIntervalSince1970: 1_791_100_000)
        let (project, services, leases) = try await leasedCheckout(udid: "SVC-RENEW", t0: t0)
        defer { project.remove() }
        let ctx = try await services.open(worktree: nil, idle: 60)
        #expect(ctx.idleOverride == 60)
        #expect(try #require(leases.load("SVC-RENEW")).renewedAt > t0)
        #expect(LeaseHolds.shared.isHolding("SVC-RENEW"))
        LeaseHolds.shared.release("SVC-RENEW")
    }

    @Test func openWithoutRenewalHoldsOnly() async throws {
        let t0 = Date(timeIntervalSince1970: 1_791_100_000)
        let (project, services, leases) = try await leasedCheckout(udid: "SVC-HOLD", t0: t0)
        defer { project.remove() }
        _ = try await services.open(worktree: nil, renewsLeases: false)
        #expect(try #require(leases.load("SVC-HOLD")).renewedAt == t0)
        #expect(LeaseHolds.shared.isHolding("SVC-HOLD"))
        LeaseHolds.shared.release("SVC-HOLD")
    }
}
