import Foundation

/// Begins or keeps a clone's idle session once a command has booted it, by any path: `DeviceProvisioner.boot`, the
/// UI runner's own boot, or `xcd test` before its xcodebuild run boots it.
public struct IdleSessions: Sendable {
    public let leases: DeviceLeases
    public let watchdogs: Watchdogs
    /// The xcd the watchdog runs as: this binary, unless a test names another.
    public let executable: String

    public init(leases: DeviceLeases, detached: any DetachedProcessLaunching, executable: String,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.leases = leases
        self.watchdogs = Watchdogs(leases: leases, detached: detached, now: now)
        self.executable = executable
    }

    /// The clone `name` is booted now, or is about to be (`xcd test`). A session is new when there is no lease or its watchdog is not running; only a
    /// new one reads `simctl list`, to sweep dead sessions, writes a lease, and starts a watchdog. Returns a note when
    /// the watchdog could not start (or the lease could not be written): that never fails the command.
    ///
    /// The lock is held before the lease is written: another command's sweep may work from a `simctl list` read before
    /// this boot, and it never removes a folder whose lock is held.
    public func began(_ name: String, _ device: ProvisionedDevice, in ctx: WorktreeContext, simctl: SimctlClient) async -> String? {
        let udid = device.udid
        if let lease = leases.load(udid), watchdogs.isLive(udid) {
            await keep(lease, idle: ctx.idleOverride)
            return nil
        }
        if let catalog = try? await simctl.catalog() { leases.sweep(catalog, isLive: watchdogs.isLive) }
        do {
            try? await leases.hold(udid)
            try leases.save(newLease(name, udid: udid, in: ctx))
            let log = ctx.paths.newArtifact(in: ctx.paths.logs, kind: "watchdog-\(name)", ext: "log", now: watchdogs.now())
            try await watchdogs.start(udid, developerDir: ctx.xcode?.developerDir, log: log, executable: executable)
            return nil
        } catch {
            return Self.startFailure(error)
        }
    }

    public static func startFailure(_ error: any Error) -> String {
        "could not start the idle watchdog: \((error as? XcdError)?.message ?? "\(error)"); the clone stays booted until xcd sim shutdown"
    }

    /// A running session: this command's `--idle` replaces its threshold, and its lease is held while the command runs.
    private func keep(_ lease: DeviceLease, idle: Int?) async {
        if let idle, idle != lease.idle {
            var changed = lease
            changed.idle = idle
            try? leases.save(changed)
        }
        try? await leases.hold(lease.udid)
    }

    private func newLease(_ name: String, udid: String, in ctx: WorktreeContext) -> DeviceLease {
        let now = watchdogs.now()
        return DeviceLease(udid: udid, device: name, worktree: ctx.state.name, worktreeRoot: ctx.location.worktreeRoot,
                           project: ctx.state.project, developerDir: ctx.xcode?.developerDir, bootedAt: now, renewedAt: now,
                           idle: ctx.idleOverride ?? ctx.config.idleSeconds)
    }
}
