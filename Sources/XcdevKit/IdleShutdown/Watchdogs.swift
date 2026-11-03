import Darwin
import Foundation

/// A clone's running watchdog, kept in `<devices>/<udid>/watchdog.json` so later commands find it live.
public struct WatchdogRecord: Codable, Sendable, Equatable {
    public let process: ProcessIdentity
    public let udid: String
    public let startedAt: Date
    public let log: String

    public init(process: ProcessIdentity, udid: String, startedAt: Date, log: String) {
        self.process = process
        self.udid = udid
        self.startedAt = startedAt
        self.log = log
    }
}

/// One watchdog per booted clone: `xcd _watch-device <udid>`, detached in a session of its own like `_record-window`,
/// so it outlives the command that booted the clone.
public struct Watchdogs: Sendable {
    /// The argument that identifies a watchdog, so a reused pid is never taken for one.
    public static let marker = "_watch-device"
    /// SIGTERM ends a watchdog between polls; after this long it is killed.
    public static let stopTimeout = Duration.seconds(5)

    public let leases: DeviceLeases
    public let detached: any DetachedProcessLaunching
    public let now: @Sendable () -> Date

    public init(leases: DeviceLeases, detached: any DetachedProcessLaunching, now: @escaping @Sendable () -> Date = { Date() }) {
        self.leases = leases
        self.detached = detached
        self.now = now
    }

    /// Nil when there is no record or it cannot be read.
    public func record(_ udid: String) -> WatchdogRecord? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: leases.files(udid).watchdog)) else { return nil }
        return try? JSONCoding.decoder.decode(WatchdogRecord.self, from: data)
    }

    /// Whether the recorded watchdog still runs: same pid and start time, and still a watchdog.
    public func isLive(_ udid: String) -> Bool {
        record(udid).map { detached.inspector.isRunning($0.process, marker: Self.marker) } ?? false
    }

    /// Starts the clone's watchdog unless one is live. Under `start.lock`, so two commands booting the clone at once
    /// start one. Its `XCDEV_HOME` is this command's, so it reads the same `devices/` folder whatever its parent's
    /// environment says. It runs in `/`: it reads only absolute paths, and a process living for hours in a worktree
    /// would keep that worktree's volume busy. The record is written at once; a watchdog whose record cannot be
    /// written is stopped again.
    public func start(_ udid: String, developerDir: String?, log: String, executable: String) async throws {
        try await FileLock.withLock(at: leases.files(udid).startLock) {
            guard !isLive(udid) else { return }
            let arguments = [Self.marker, udid] + (developerDir.map { ["--developer-dir", $0] } ?? [])
            let invocation = Invocation(executable, arguments, environment: ["XCDEV_HOME": leases.globalPaths.base],
                                        workingDirectory: "/")
            let process = try detached.start(invocation, log: log)
            do {
                try save(WatchdogRecord(process: process, udid: udid, startedAt: now(), log: log))
            } catch {
                _ = await detached.stop(process, marker: Self.marker, signal: SIGTERM, timeout: Self.stopTimeout)
                throw error
            }
        }
    }

    /// Ends the clone's session: holds its lease (so the watchdog cannot act on it meanwhile), stops a live watchdog,
    /// and removes the lease and the record.
    public func end(_ udid: String) async {
        try? await leases.hold(udid)
        if let record = record(udid) {
            _ = await detached.stop(record.process, marker: Self.marker, signal: SIGTERM, timeout: Self.stopTimeout)
        }
        leases.remove(udid)
    }

    func save(_ record: WatchdogRecord) throws {
        let files = leases.files(record.udid)
        try Disk.makeFolder(files.folder)
        try JSONCoding.encoder(pretty: true).encode(record).write(to: URL(fileURLWithPath: files.watchdog), options: .atomic)
    }
}
