import Foundation

/// Every booted simulator, listed on the check's `ok` line: whose it is, how long it has been up, when a command last
/// used it, its idle threshold, and whether its watchdog runs.
///
/// A clone a registered worktree records, with no live watchdog, is a problem `--fix` repairs by starting one (and
/// writing its lease when it has none); a lease with idle off needs none. A simulator xcd did not boot is a problem
/// only once it has been up for `dayLimit`, and it is never shut down: the user is asked. Doctor shuts nothing down.
public struct BootedSimulatorsCheck: DoctorCheck {
    public let id = "booted-simulators"
    /// How long a simulator xcd did not boot may stay up before it is reported.
    public let dayLimit: TimeInterval
    public init(dayLimit: TimeInterval = 86_400) { self.dayLimit = dayLimit }

    public func summary(_ env: DoctorEnvironment) async -> String? {
        let booted = await Self.listing(env)
        guard !booted.isEmpty else { return "none booted" }
        return "\(booted.count) booted: " + booted.map { $0.clause(now: env.now) }.joined(separator: "; ")
    }

    public func detect(_ env: DoctorEnvironment) async -> [DoctorProblem] {
        await Self.listing(env).compactMap { problem(for: $0, now: env.now) }
    }

    func problem(for simulator: BootedSimulator, now: Date) -> DoctorProblem? {
        if let recorder = simulator.recorder {
            return simulator.needsWatchdog ? unwatched(simulator, recorder, now: now) : nil
        }
        guard simulator.lease == nil, let age = simulator.age(now: now), age >= dayLimit else { return nil }
        let udid = simulator.device.udid
        return DoctorProblem(check: id, message: "\(simulator.device.name) (not xcd's): booted \(BootedSimulator.duration(age))",
                             next: "ask the user before shutting it down: `xcrun simctl shutdown \(udid)`", subject: udid)
    }

    /// A clone of a registered worktree with no live watchdog: `<owner>: booted <age>, used <q> ago, no watchdog`.
    func unwatched(_ simulator: BootedSimulator, _ recorder: BootedSimulator.Recorder, now: Date) -> DoctorProblem {
        let booted = simulator.age(now: now).map { "booted \(BootedSimulator.duration($0))" }
        let parts = [booted, simulator.used(now: now).map { "used \($0) ago" }, "no watchdog"].compactMap { $0 }
        return DoctorProblem(check: id, message: "\(simulator.label): " + parts.joined(separator: ", "), action: .startWatchdog,
                             fix: "start its idle watchdog", next: "run `xcd doctor --fix` to start one", subject: simulator.device.udid,
                             done: "watchdog started", projectRoot: recorder.entry.projectRoot)
    }

    /// Starts the clone's watchdog under its worktree's lock, taken without waiting as the worktree fixes take it: a
    /// held lock means a `wt create` or `wt remove` is running, and the clone is left to it.
    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws {
        guard let udid = problem.subject, let recorder = BootedSimulator.recorder(of: udid, env) else { return }
        let entry = recorder.entry
        let worktrees = WorktreeService(runner: env.runner, globalPaths: env.globalPaths)
        let lock = worktrees.lockPath(projectRoot: entry.projectRoot, worktree: entry.name)
        let ran: Void? = try await FileLock.withLockIfFree(at: lock) { try await startWatchdog(udid, recorder, env) }
        guard ran != nil else { throw DoctorLeftAlone(note: DoctorEnvironment.busyNote(entry)) }
    }

    /// With the lock held, the worktree's state is read again: a clone it no longer records is left as it is. A clone
    /// with no lease gets one first, with the threshold of its checkout's config.
    func startWatchdog(_ udid: String, _ recorder: BootedSimulator.Recorder, _ env: DoctorEnvironment) async throws {
        let paths = WorktreePaths(root: recorder.entry.path)
        guard let state = try WorktreeStateStore.load(paths), state.devices[recorder.device]?.udid == udid else { return }
        let lease = try await lease(of: udid, recorder, xcode: state.xcode, env)
        let log = paths.newArtifact(in: paths.logs, kind: "watchdog-\(recorder.device)", ext: "log", now: env.now)
        let now = env.now
        try await Watchdogs(leases: DeviceLeases(globalPaths: env.globalPaths), detached: env.detached, now: { now })
            .start(udid, developerDir: lease.developerDir, log: log, executable: env.xcdExecutable)
    }

    /// The clone's lease. One is written for a clone that has none: booted when its `launchd_sim` started (else now),
    /// renewed now, with its checkout's threshold and its worktree's Xcode.
    func lease(of udid: String, _ recorder: BootedSimulator.Recorder, xcode: XcodeInstall?,
               _ env: DoctorEnvironment) async throws -> DeviceLease {
        let leases = DeviceLeases(globalPaths: env.globalPaths)
        if let lease = leases.load(udid) { return lease }
        let entry = recorder.entry
        let config = try? ConfigLoader.checkout(worktreeRoot: entry.path, projectRoot: entry.projectRoot).config
        let bootedAt = await BootedSimulator.bootTimes([udid], env)[udid] ?? env.now
        let lease = DeviceLease(udid: udid, device: recorder.device, worktree: entry.name, worktreeRoot: entry.path,
                                project: entry.project, developerDir: xcode?.developerDir, bootedAt: bootedAt, renewedAt: env.now,
                                idle: config?.idleSeconds ?? IdleThreshold.defaultSeconds)
        try leases.save(lease)
        return lease
    }

    /// Every booted simulator, as the check's problems and summary see it.
    static func listing(_ env: DoctorEnvironment) async -> [BootedSimulator] {
        let booted = env.catalog?.devices.filter { $0.state == "Booted" } ?? []
        guard !booted.isEmpty else { return [] }
        let starts = await BootedSimulator.bootTimes(booted.map(\.udid), env)
        let leases = DeviceLeases(globalPaths: env.globalPaths)
        let watchdogs = Watchdogs(leases: leases, detached: env.detached)
        return booted.map { device in
            let lease = leases.load(device.udid)
            return BootedSimulator(device: device, bootedAt: starts[device.udid] ?? lease?.bootedAt, lease: lease,
                                   recorder: BootedSimulator.recorder(of: device.udid, env), watched: watchdogs.isLive(device.udid))
        }
    }
}

/// One booted simulator: when it booted, its lease, the worktree that records it, and whether its watchdog runs.
struct BootedSimulator: Sendable {
    /// The registered worktree whose state records a clone, and the clone's device name there.
    struct Recorder: Sendable {
        let entry: RegistryEntry
        let device: String
    }

    let device: SimDevice
    /// Its `launchd_sim`'s start, else its lease's `bootedAt`; nil when neither can be read.
    let bootedAt: Date?
    let lease: DeviceLease?
    let recorder: Recorder?
    /// Whether its recorded watchdog still runs.
    let watched: Bool

    /// `project/worktree device` from its lease, else from the worktree that records it; nil when xcd did not boot it.
    var owner: String? {
        if let lease { return "\(lease.project)/\(lease.worktree) \(lease.device)" }
        return recorder.map { "\($0.entry.project)/\($0.entry.name) \($0.device)" }
    }

    /// Its owner, or its simulator name when xcd did not boot it.
    var label: String { owner ?? device.name }

    /// A clone of a registered worktree that would shut down when idle, but whose watchdog is not running.
    var needsWatchdog: Bool { recorder != nil && !watched && lease?.idle != 0 }

    func age(now: Date) -> TimeInterval? { bootedAt.map { now.timeIntervalSince($0) } }

    /// How long ago a command last renewed its lease, as text; nil without a lease.
    func used(now: Date) -> String? { lease.map { Self.duration(TimeInterval($0.quietSeconds(now: now))) } }

    /// Its part of the summary: `<owner> <age> (used <q> ago, idle <t>, watchdog running)`, and the like.
    func clause(now: Date) -> String {
        let head = [label, age(now: now).map(Self.duration)].compactMap { $0 }.joined(separator: " ")
        guard owner != nil else { return head + " (not xcd's)" }
        guard let lease, let used = used(now: now) else { return head + " (no watchdog)" }
        if lease.idle == 0 { return head + " (used \(used) ago, idle off: never shuts down)" }
        return head + (watched ? " (used \(used) ago, idle \(IdleThreshold.text(lease.idle)), watchdog running)" : " (no watchdog)")
    }

    /// `45s`, `25m`, `2h 10m`, `3d 4h`.
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return "\(whole / 60)m" }
        if whole < 86_400 { return "\(whole / 3600)h \(whole % 3600 / 60)m" }
        return "\(whole / 86_400)d \(whole % 86_400 / 3600)h"
    }

    /// The registered worktree whose state records `udid`, and the device name it records it as.
    static func recorder(of udid: String, _ env: DoctorEnvironment) -> Recorder? {
        for entry in env.registry {
            let names = env.states[entry.id]?.devices.filter { $0.value.udid == udid }.map(\.key).sorted() ?? []
            if let name = names.first { return Recorder(entry: entry, device: name) }
        }
        return nil
    }

    /// When each of `udids` booted: the start of the `launchd_sim` whose arguments name its device folder
    /// (`…/Devices/<udid>/data/var/run/launchd_bootstrap.plist`). A process that exited since `ps` listed it, or
    /// whose arguments cannot be read, is skipped, and so is a failed `ps`: that simulator has no boot time.
    static func bootTimes(_ udids: [String], _ env: DoctorEnvironment) async -> [String: Date] {
        let pids = (try? await ProcessLookup(runner: env.runner).pids(named: "launchd_sim")) ?? []
        var times: [String: Date] = [:]
        for pid in pids.sorted() {
            guard let process = env.detached.inspector.identity(of: pid) else { continue }
            for udid in udids where process.arguments.contains(where: { $0.contains("/Devices/\(udid)/") }) {
                times[udid] = Date(timeIntervalSince1970: process.startTime)
            }
        }
        return times
    }
}
