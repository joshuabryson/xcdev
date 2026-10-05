import Darwin
import Foundation

/// What a `ui` command needs to talk to its clone's runner.
public struct RunnerSession: Sendable, Equatable {
    public let device: String
    public let udid: String
    public let port: Int
    public let token: String
    /// True when this command had to replace a runner that had stopped working.
    public let restarted: Bool

    public var endpoint: RunnerEndpoint { RunnerEndpoint(port: port, token: token) }
}

/// Starts, finds, checks, restarts, and stops the UI runner of a worktree's clone.
public struct RunnerSupervisor: Sendable {
    public let provisioner: DeviceProvisioner
    public let builder: RunnerBuilder
    public let detached: any DetachedProcessLaunching
    public let client: RunnerClient
    public let globalPaths: GlobalPaths
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void

    public init(provisioner: DeviceProvisioner, builder: RunnerBuilder, detached: any DetachedProcessLaunching, client: RunnerClient,
                globalPaths: GlobalPaths, now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.provisioner = provisioner
        self.builder = builder
        self.detached = detached
        self.client = client
        self.globalPaths = globalPaths
        self.now = now
        self.sleep = sleep
    }

    /// How long a start may take: a warm clone answers in seconds; a cold one may be doing its first boot, which took
    /// over six minutes on a loaded Mac.
    public static func startTimeout(warm: Bool) -> Duration { warm ? .seconds(120) : .seconds(600) }

    /// How long after it was created a clone may still be finishing its first boot.
    static let settlingTime: TimeInterval = 15 * 60

    /// Whether `clone` (as it was before this command) will start a runner quickly: it was already booted, and it was
    /// created long enough ago to have settled. `xcd run` boots a new clone before the first `xcd ui`, so being booted
    /// is not enough. No clone yet, or a creation date that can't be read, counts as cold.
    func isWarm(_ clone: SimDevice?) -> Bool {
        guard let clone, clone.state == "Booted", let created = clone.created else { return false }
        return now().timeIntervalSince(created) >= Self.settlingTime
    }

    /// A healthy runner for the device: the one already running, or a new one. `restart` replaces it regardless.
    public func session(device requested: String?, in ctx: inout WorktreeContext, restart: Bool = false) async throws -> RunnerSession {
        let name = try provisioner.deviceName(requested, config: ctx.config)
        // The clone as it is before this command touches it decides how long the start may take.
        let catalog = try? await provisioner.simctl(for: ctx).catalog()
        let warm = isWarm(ctx.state.devices[name].flatMap { catalog?.device(udid: $0.udid) })
        // Clone first and check the platform, so a watch or TV device is rejected without being booted.
        let device = try await provisioner.ensure(name, in: &ctx)
        try Runners.requireIOS(device, name: name)
        _ = try await provisioner.simctl(for: ctx).boot(udid: device.udid)
        let xcode = try await provisioner.ensureXcode(&ctx)
        let target = Target(name: name, udid: device.udid, key: builder.key(for: xcode), developerDir: xcode.developerDir,
                            paths: ctx.paths, timeout: Self.startTimeout(warm: warm))
        let lock = Runners.lockPath(globalPaths: globalPaths, worktreeRoot: ctx.location.worktreeRoot, device: name)
        return try await FileLock.withLock(at: lock) { try await attachOrStart(target, xcode: xcode, restart: restart) }
    }

    /// Stops the device's runner and forgets a failed one. Returns what it stopped.
    public func stop(device requested: String?, in ctx: WorktreeContext) async throws -> [String] {
        let name = try provisioner.deviceName(requested, config: ctx.config)
        return await Runners.stopAll(in: ctx.paths, device: name, detached: detached)
    }

    /// Everything one start-or-attach needs to know about the clone it serves.
    struct Target: Sendable {
        let name: String
        let udid: String
        let key: String
        let developerDir: String
        let paths: WorktreePaths
        let timeout: Duration
    }

    /// Runs under the device's lock: attach to the recorded runner if it is usable, else replace it.
    func attachOrStart(_ target: Target, xcode: XcodeInstall, restart: Bool) async throws -> RunnerSession {
        let file = target.paths.runnerFile(device: target.name)
        var restarts: [Date] = []
        var replacing = false
        if let record = Runners.load(file) {
            if record.failed { throw Self.gaveUp(target.name, record: record, message: "the \(target.name) UI runner keeps stopping and was given up on") }
            if !restart, await healthy(record, udid: target.udid, key: target.key), let port = record.port {
                return RunnerSession(device: target.name, udid: target.udid, port: port, token: record.token, restarted: false)
            }
            // A runner was here and can't be used: this start replaces it. `Runners.stop` signals only a process
            // that is still the recorded one.
            replacing = true
            await Runners.stop(record, file: file, detached: detached)
            restarts = record.restarts.filter { now().timeIntervalSince($0) < 60 } + [now()]
            if restarts.count >= 2 {
                var failed = record
                failed.failed = true
                failed.restarts = restarts
                try Runners.save(failed, to: file)
                throw Self.gaveUp(target.name, record: record, message: "the \(target.name) UI runner keeps stopping: it was restarted twice within a minute")
            }
        }
        let build = try await builder.ensureBuilt(xcode: xcode)
        let record = try await start(target, build: build, restarts: restarts)
        guard let port = record.port else { throw XcdError(.internalError, "the \(target.name) UI runner started without a port") }
        return RunnerSession(device: target.name, udid: target.udid, port: port, token: record.token, restarted: replacing)
    }

    static func gaveUp(_ name: String, record: RunnerRecord, message: String) -> XcdError {
        XcdError(.runnerFailed, message, next: "run `xcd ui stop`, then `xcd doctor`", details: ["log: \(record.log)"])
    }

    /// The record's process still runs, it is this clone's and this Xcode's runner, and it answers `/health`. A live
    /// xcodebuild whose runner doesn't answer is not healthy: xcodebuild can outlive its runner by minutes.
    func healthy(_ record: RunnerRecord, udid: String, key: String) async -> Bool {
        guard let endpoint = record.endpoint, record.udid == udid, record.runnerKey == key,
              detached.inspector.isRunning(record.process, marker: Runners.marker) else { return false }
        return await client.health(endpoint) != nil
    }

    func start(_ target: Target, build: RunnerBuild, restarts: [Date]) async throws -> RunnerRecord {
        var retried = false
        while true {
            let record = try launch(target, build: build, restarts: restarts)
            let file = target.paths.runnerFile(device: target.name)
            let ready: RunnerRecord?
            do {
                try Runners.save(record, to: file)                  // findable from now on, even if this xcd is interrupted
                ready = try await waitUntilReady(record, timeout: target.timeout)
                if let ready { try Runners.save(ready, to: file) }
            } catch {
                await Runners.stop(record, file: file, detached: detached)
                throw error
            }
            if let ready { return ready }
            // xcodebuild exited before the runner was up.
            let tail = Self.tail(record.log)
            await Runners.stop(record, file: file, detached: detached)
            if !retried, tail.contains(where: { $0.contains("Unable to find a device matching") }) {
                retried = true                                      // seen once just after a clone was created
                continue
            }
            throw XcdError(.runnerFailed, "the \(target.name) UI runner stopped before it was ready",
                           next: "run `xcd doctor`; if it keeps happening, `xcd ui stop --rebuild`", details: ["log: \(record.log)"] + tail)
        }
    }

    func launch(_ target: Target, build: RunnerBuild, restarts: [Date]) throws -> RunnerRecord {
        let token = UUID().uuidString
        // The runner, a process inside the simulator, writes this file. It goes in xcd's cache, not the worktree: macOS
        // can deny or prompt for a write into a project under Documents, Desktop, Downloads, or iCloud Drive.
        let ready = globalPaths.runnerReadyFile(udid: target.udid)
        let log = target.paths.runnerLog(device: target.name)
        try? FileManager.default.removeItem(atPath: ready)
        try FileManager.default.createDirectory(atPath: (ready as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // xcodebuild writes a result bundle per run; keep only this clone's latest.
        let results = build.directory + "/results"
        try? FileManager.default.removeItem(atPath: results + "/\(target.udid).xcresult")
        try FileManager.default.createDirectory(atPath: results, withIntermediateDirectories: true)
        var invocation = Invocation.xcrun(["xcodebuild", "test-without-building", "-xctestrun", build.xctestrun,
                                           "-destination", "id=\(target.udid)", "-resultBundlePath", results + "/\(target.udid).xcresult"],
                                          developerDir: target.developerDir)
        invocation.environment["TEST_RUNNER_XCD_TOKEN"] = token
        invocation.environment["TEST_RUNNER_XCD_READY_FILE"] = ready
        let process = try detached.start(invocation, log: log)
        return RunnerRecord(device: target.name, udid: target.udid, process: process, token: token, port: nil, runnerKey: build.key,
                            log: log, readyFile: ready, startedAt: now(), restarts: restarts, failed: false)
    }

    /// Waits for the ready file and a `/health` answer. Returns nil when xcodebuild exits first; throws on timeout.
    /// Polls every 200 ms, counted in attempts so tests with an instant `sleep` don't spin.
    func waitUntilReady(_ record: RunnerRecord, timeout: Duration) async throws -> RunnerRecord? {
        let attempts = max(1, Int((DurationText.seconds(timeout) * 5).rounded()))
        for _ in 0..<attempts {
            if let port = Self.port(in: record.readyFile), await client.health(RunnerEndpoint(port: port, token: record.token)) != nil {
                var ready = record
                ready.port = port
                return ready
            }
            guard detached.inspector.isRunning(record.process) else { return nil }
            try await sleep(.milliseconds(200))
        }
        throw XcdError(.runnerFailed, "the \(record.device) UI runner did not start within \(DurationText.format(timeout))",
                       next: "run `xcd doctor`; a simulator's first boot can take minutes on a busy Mac, so retrying may be enough",
                       details: ["log: \(record.log)"] + Self.tail(record.log))
    }

    static func port(in readyFile: String) -> Int? {
        guard let data = FileManager.default.contents(atPath: readyFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["port"] as? Int
    }

    static func tail(_ log: String) -> [String] {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").suffix(20).map(String.init)
    }
}
