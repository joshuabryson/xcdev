import Darwin
import Foundation

/// What the watchdog does after one poll.
public enum WatchdogStep: Equatable, Sendable {
    /// Nothing to do yet: poll again after `pollInterval`.
    case wait
    /// The shutdown failed: try again after `retryInterval`.
    case retry
    /// The watchdog is done, with this exit code.
    case exit(Int32)
}

/// The loop of `xcd _watch-device <udid>`, the detached process `Watchdogs.start` launches for each booted clone. It
/// shuts its clone down once the lease is stale and no command holds `lease.lock`, then exits. A live UI runner or
/// recording does not keep the clone booted: a stale lease stops them first. It reads files and runs `simctl` for its
/// own udid only; it never opens a worktree context and never renews.
public struct DeviceWatchdog: Sendable {
    public static let pollInterval = Duration.seconds(5)
    /// How often `simctl list` is read, to notice a clone shut down by something else.
    public static let listInterval: TimeInterval = 60
    public static let retryInterval = Duration.seconds(10)
    /// Failed shutdowns before the watchdog gives up.
    public static let attempts = 3

    public let udid: String
    public let leases: DeviceLeases
    public let simctl: SimctlClient
    public let detached: any DetachedProcessLaunching
    /// This process: the record is deleted on the way out only while it names this pid.
    public let ownPid: Int32
    public let now: @Sendable () -> Date
    public let log: @Sendable (String) -> Void
    private var lastList: Date?
    /// The last poll that found `lease.lock` held: quiet time counts from it when it is later than the renewal.
    private var lastHeld: Date?
    /// Failed tries in a row: a poll that waits starts the count again.
    private var failures = 0

    public init(udid: String, leases: DeviceLeases, simctl: SimctlClient, detached: any DetachedProcessLaunching,
                ownPid: Int32 = getpid(), now: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void) {
        self.udid = udid
        self.leases = leases
        self.simctl = simctl
        self.detached = detached
        self.ownPid = ownPid
        self.now = now
        self.log = log
    }

    private var files: DeviceFiles { leases.files(udid) }

    /// One turn of the loop. A poll that waits resets the failure count, so `attempts` counts failures in a row.
    public mutating func poll() async -> WatchdogStep {
        let step = await nextStep()
        if step == .wait { failures = 0 }
        return step
    }

    private mutating func nextStep() async -> WatchdogStep {
        guard let lease = leases.load(udid) else { return ended(code: 0) }
        guard await listed() else { return await notBooted() }
        guard !FileLock.isHeld(at: files.lock) else { return held() }
        guard isStale(lease) else { return .wait }
        return await shutDown(lease)
    }

    /// Shuts the clone down under an exclusive try of `lease.lock` (taken by a command meanwhile: `.wait`). `seen` is
    /// the lease the poll judged stale; one renewed since, or no longer stale, is left alone.
    mutating func shutDown(_ seen: DeviceLease) async -> WatchdogStep {
        do {
            guard let step = try await FileLock.withLockIfFree(at: files.lock, { try await shutDownHolding(seen) }) else {
                return held()
            }
            return step
        } catch {
            return failed("shutdown failed: ", error)
        }
    }

    /// The list shows the clone not booted, or gone. A command holding the lease may be about to boot it (`xcd test`'s
    /// xcodebuild does), so the session ends only under an exclusive try of `lease.lock` (taken: `.wait`).
    private mutating func notBooted() async -> WatchdogStep {
        do {
            guard let step = try await FileLock.withLockIfFree(at: files.lock, { await endUnlessBooted() }) else { return held() }
            return step
        } catch {
            return failed("could not take the lease's lock: ", error)
        }
    }

    /// A command holds the lease: the clone is in use now, so its quiet time starts again.
    private mutating func held() -> WatchdogStep {
        lastHeld = now()
        return .wait
    }

    /// Inside the lock, the list is read again: a clone booted meanwhile keeps its session, as does a list that cannot
    /// be read. Otherwise the lease and this watchdog's record go before the lock is let go.
    private func endUnlessBooted() async -> WatchdogStep {
        do {
            if try await simctl.catalog().device(udid: udid)?.state == "Booted" { return .wait }
        } catch {
            logFailure("simctl list failed: ", error)
            return .wait
        }
        log("\(udid) is no longer booted")
        Disk.remove(files.lease)
        return ended(code: 0)
    }

    /// Polls until the watchdog is done; returns its exit code.
    public mutating func run(sleep: @Sendable (Duration) async -> Void) async -> Int32 {
        while true {
            switch await poll() {
            case .wait: await sleep(Self.pollInterval)
            case .retry: await sleep(Self.retryInterval)
            case .exit(let code): return code
            }
        }
    }

    /// Every file change happens here, before the lock is let go: a command waiting on its hold then finds neither the
    /// lease nor the record, so it begins a new session with a new watchdog.
    private func shutDownHolding(_ seen: DeviceLease) async throws -> WatchdogStep {
        guard let lease = leases.load(udid) else { return ended(code: 0) }
        guard lease.renewedAt == seen.renewedAt, isStale(lease) else { return .wait }
        let quiet = judged(lease).quietSeconds(now: now())
        await stopUsers(of: lease)
        try await simctl.shutdown(udid: udid)
        Disk.remove(files.lease)
        let step = ended(code: 0)
        log("shut down \(udid) after \(quiet) s idle")
        return step
    }

    /// The lease as the watchdog judges it: quiet since its renewal, or since the last poll that saw it held when that
    /// came later. Doctor's "used … ago" still counts from the renewal.
    private func judged(_ lease: DeviceLease) -> DeviceLease {
        guard let lastHeld, lastHeld > lease.renewedAt else { return lease }
        var judged = lease
        judged.renewedAt = lastHeld
        return judged
    }

    private func isStale(_ lease: DeviceLease) -> Bool {
        judged(lease).isStale(now: now(), rootExists: Disk.exists(lease.worktreeRoot))
    }

    /// Whether the clone still counts as booted. `simctl list` is read on the first poll and then once per
    /// `listInterval`; between reads, and when a read fails, it does.
    private mutating func listed() async -> Bool {
        let time = now()
        if let lastList, time.timeIntervalSince(lastList) < Self.listInterval { return true }
        lastList = time
        do {
            return try await simctl.catalog().device(udid: udid)?.state == "Booted"
        } catch {
            logFailure("simctl list failed: ", error)
            return true
        }
    }

    /// Stops what ran against the clone, as `sim shutdown` does: its recordings first, so the video is finished, then its
    /// UI runner. A record of the same device name for another udid (the device was cloned again) is left alone.
    private func stopUsers(of lease: DeviceLease) async {
        let paths = WorktreePaths(root: lease.worktreeRoot)
        let recordings = await Recordings.stopAll(in: paths, device: lease.device, udid: udid, detached: detached, now: now())
        let runners = await Runners.stopAll(in: paths, device: lease.device, udid: udid, detached: detached)
        (recordings.map(\.note) + runners).forEach(log)
    }

    /// After `attempts` failures the watchdog gives up, keeping the lease, so doctor shows a booted clone with no
    /// watchdog rather than a silent loop.
    private mutating func failed(_ prefix: String, _ error: any Error) -> WatchdogStep {
        failures += 1
        logFailure(prefix, error)
        guard failures >= Self.attempts else { return .retry }
        log("giving up")
        return ended(code: 1)
    }

    /// Deletes the record only while it names this process: a newer watchdog of the same udid keeps its own.
    private func ended(code: Int32) -> WatchdogStep {
        if Watchdogs(leases: leases, detached: detached).record(udid)?.process.pid == ownPid { Disk.remove(files.watchdog) }
        return .exit(code)
    }

    /// Logs `prefix` and the error's message, then its details (simctl's stderr among them), indented.
    private func logFailure(_ prefix: String, _ error: any Error) {
        guard let error = error as? XcdError else { return log(prefix + "\(error)") }
        log(prefix + error.message)
        error.details.forEach { log("  " + $0) }
    }
}
