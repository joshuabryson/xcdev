import Foundation

/// Where a clone's idle session is kept: `<XCDEV_HOME>/devices/<udid>/`.
public struct DeviceFiles: Sendable, Equatable {
    public let folder, lease, lock, watchdog, startLock: String

    public init(udid: String, globalPaths: GlobalPaths) {
        folder = globalPaths.devicesDirectory + "/" + udid
        lease = folder + "/lease.json"
        lock = folder + "/lease.lock"
        watchdog = folder + "/watchdog.json"
        startLock = folder + "/start.lock"
    }
}

/// The fact that a clone is in use: renewed by every command, read by the clone's watchdog.
public struct DeviceLease: Codable, Sendable, Equatable {
    public let udid, device, worktree, worktreeRoot, project: String
    public let developerDir: String?
    public let bootedAt: Date
    public var renewedAt: Date
    /// Seconds of quiet before the clone is shut down; 0 = never.
    public var idle: Int

    public init(udid: String, device: String, worktree: String, worktreeRoot: String, project: String,
                developerDir: String?, bootedAt: Date, renewedAt: Date, idle: Int) {
        self.udid = udid
        self.device = device
        self.worktree = worktree
        self.worktreeRoot = worktreeRoot
        self.project = project
        self.developerDir = developerDir
        self.bootedAt = bootedAt
        self.renewedAt = renewedAt
        self.idle = idle
    }

    /// Seconds since the last renewal; a renewal in the future counts as now (0).
    public func quietSeconds(now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(renewedAt)))
    }

    /// idle 0 is never stale; a vanished worktree root is stale at once; otherwise the quiet time has reached `idle`.
    public func isStale(now: Date, rootExists: Bool) -> Bool {
        guard idle > 0 else { return false }
        return !rootExists || quietSeconds(now: now) >= idle
    }
}

public struct DeviceLeases: Sendable {
    public let globalPaths: GlobalPaths
    public let holds: LeaseHolds

    public init(globalPaths: GlobalPaths, holds: LeaseHolds = .shared) {
        self.globalPaths = globalPaths
        self.holds = holds
    }

    public func files(_ udid: String) -> DeviceFiles { DeviceFiles(udid: udid, globalPaths: globalPaths) }

    /// Nil when there is no lease or it cannot be read (hand-edited, cut short, or from a later xcd).
    public func load(_ udid: String) -> DeviceLease? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: files(udid).lease)) else { return nil }
        return try? JSONCoding.decoder.decode(DeviceLease.self, from: data)
    }

    public func save(_ lease: DeviceLease) throws {
        let files = files(lease.udid)
        try Disk.makeFolder(files.folder)
        let data = try JSONCoding.encoder(pretty: true).encode(lease)
        try data.write(to: URL(fileURLWithPath: files.lease), options: .atomic)
    }

    /// Touches the leases that exist; a clone with none has no session to keep. Write errors are ignored: a command
    /// that cannot renew still runs, and the worst case is an earlier shutdown.
    public func renew(_ udids: [String], now: Date) {
        for udid in udids {
            guard var lease = load(udid) else { continue }
            lease.renewedAt = now
            try? save(lease)
        }
    }

    /// Holds, then renews (when asked), every lease of the worktree's devices. The hold comes first: it waits out a
    /// watchdog shutting the clone down under its exclusive lock, and the renewal then finds the lease gone, so it never
    /// brings back a session that ended.
    public func keep(_ state: WorktreeState, renewing: Bool, now: Date) async throws {
        let leased = state.devices.values.map(\.udid).filter { load($0) != nil }
        for udid in leased { try await hold(udid) }
        if renewing { renew(leased, now: now) }
    }

    public func hold(_ udid: String) async throws {
        try await holds.hold(udid, at: files(udid).lock)
    }

    /// Ends a session: the lock file stays, since a holder may have it open.
    public func remove(_ udid: String) {
        let files = files(udid)
        Disk.remove(files.lease)
        Disk.remove(files.watchdog)
    }

    /// Housekeeping when a session begins: removes the whole folder of a clone that is gone from `catalog`, or shut
    /// down with no live watchdog. A folder whose lock is held stays, since a command may be using it.
    public func sweep(_ catalog: SimCatalog, isLive: (String) -> Bool) {
        for udid in Disk.names(in: globalPaths.devicesDirectory) {
            let state = catalog.device(udid: udid)?.state
            guard state == nil || (state == "Shutdown" && !isLive(udid)) else { continue }
            let files = files(udid)
            if !FileLock.isHeld(at: files.lock) { Disk.remove(files.folder) }
        }
    }
}
