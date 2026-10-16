import Foundation

/// CoreSimulator answers `simctl list`. Fix: restart its service (launchd starts it again on demand).
///
/// Restarting CoreSimulator shuts down every simulator on the Mac, including other agents', so a failed list
/// is first retried (see `listCatalog`), and the restart is offered only when the failure is CoreSimulator's
/// (see `isCoreSimulatorFailure`). Any other failure is reported with a `next:` line and no fix.
public struct CoreSimulatorCheck: DoctorCheck {
    public let id = "coresimulator"
    public init() {}

    /// Attempts at `simctl list` before doctor concludes it fails, and the pause between them.
    static let listAttempts = 3
    static let listRetryDelay = Duration.seconds(1)

    public func detect(_ env: DoctorEnvironment) async -> [DoctorProblem] {
        guard env.catalog == nil else { return [] }
        let reason = env.catalogError ?? "no output"
        guard let failure = env.catalogFailure, Self.isCoreSimulatorFailure(failure) else {
            return [DoctorProblem(check: id, message: "simctl couldn't list simulators: \(reason)",
                                  next: "run `xcrun simctl list` to see the error, and check `xcode-select -p` points at an installed Xcode")]
        }
        return [DoctorProblem(check: id, message: "CoreSimulator didn't answer `simctl list`: \(reason)",
                              action: .restartCoreSimulator, fix: "restart the CoreSimulator service; every booted simulator on this Mac shuts down",
                              next: "if it still fails, quit Device Hub (Simulator.app before Xcode 27) and Xcode, or restart the Mac")]
    }

    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws {
        _ = try? await env.runner.run(Invocation("/usr/bin/pkill", ["-9", "-f", "com.apple.CoreSimulator.CoreSimulatorService"],
                                                 timeout: .seconds(10)))
        _ = try await Self.listCatalog(env.simctl)
    }

    /// `simctl list`, retried briefly: a single failure can be a blip (CoreSimulator starting up, or busy),
    /// and isn't worth restarting the service over. A timeout isn't retried; the service is already hung.
    static func listCatalog(_ simctl: SimctlClient) async throws -> SimCatalog {
        var attempt = 1
        while true {
            do {
                return try await simctl.catalog()
            } catch let error as XcdError where error.code != .timeout && attempt < listAttempts {
                attempt += 1
                try await simctl.sleep(listRetryDelay)
            }
        }
    }

    /// Whether a failed `simctl list` is CoreSimulator's fault, so restarting it may help. True when the list
    /// timed out (the service is hung), or when simctl failed and its stderr names CoreSimulator, its device set,
    /// or a broken connection to the service (e.g. "Failed to initialize simulator device set.", "CoreSimulatorService
    /// connection became invalid", NSMachErrorDomain errors). False when xcrun itself failed ("xcrun: error:",
    /// e.g. no Xcode selected), when simctl exited without saying why, and whenever simctl didn't fail at all
    /// (no `command:` detail), such as output that couldn't be parsed, whose decoding error quotes runtime ids
    /// like "com.apple.CoreSimulator.SimRuntime.iOS-27-0": a restart wouldn't fix those, and it would shut down
    /// every simulator on the Mac.
    static func isCoreSimulatorFailure(_ error: XcdError) -> Bool {
        if error.code == .timeout { return true }
        guard error.details.contains(where: { $0.hasPrefix("command: ") }) else { return false }
        let stderr = error.details.filter { !$0.hasPrefix("command: ") && !$0.hasPrefix("exit: ") }
            .joined(separator: "\n").lowercased()
        if stderr.contains("xcrun: error:") { return false }
        let markers = ["coresimulator", "device set", "nsmacherrordomain", "mach error",
                       "connection became invalid", "connection invalid", "connection interrupted", "invalidated"]
        return markers.contains { stderr.contains($0) }
    }
}

/// Templates must be available, shut down, and unique; missing ones are simply re-created on next use. xcd never boots
/// a template, so one that is not shut down was booted by someone else, who may be using it: it is left to the user.
public struct TemplatesCheck: DoctorCheck {
    public let id = "templates"
    public init() {}

    public func detect(_ env: DoctorEnvironment) async -> [DoctorProblem] {
        guard let catalog = env.catalog else { return [] }
        // Of duplicates, the first usable one (available and shut down) is kept.
        func rank(_ device: SimDevice) -> Int { device.isAvailable && device.state == "Shutdown" ? 0 : 1 }
        let templates = catalog.devices.filter { $0.name.hasPrefix(SimNaming.templatePrefix) }
            .sorted { (rank($0), $0.udid) < (rank($1), $1.udid) }
        var seen = Set<String>()
        var problems: [DoctorProblem] = []
        for template in templates {
            let label = "\(template.name) (\(template.udid))"
            if !seen.insert(template.name).inserted {
                problems.append(template.state == "Shutdown"
                    ? DoctorProblem(check: id, message: "\(label) is a duplicate template", action: .deleteSimulator, fix: "delete it",
                                    subject: template.udid)
                    : booted(template, "\(label) is a duplicate template, and it is \(template.state)"))
            } else if !template.isAvailable {
                problems.append(DoctorProblem(check: id, message: "\(label) is unavailable; its runtime may have been removed",
                                              action: .deleteSimulator, fix: "delete it; it is re-created when next needed",
                                              subject: template.udid))
            } else if template.state != "Shutdown" {
                problems.append(booted(template, "\(label) is \(template.state); clones need a shut-down template"))
            }
        }
        return problems
    }

    func booted(_ template: SimDevice, _ message: String) -> DoctorProblem {
        DoctorProblem(check: id, message: message,
                      next: "xcd never boots a template, so someone else did: ask the user before shutting it down (`xcrun simctl shutdown \(template.udid)`)",
                      subject: template.udid)
    }

    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws {
        guard let udid = problem.subject else { return }
        try await env.simctl.delete(udid: udid)
    }
}

/// Recorded clones that are unavailable (their runtime was removed) or stuck booting or shutting down.
///
/// The clones of a worktree another xcd is creating or removing are left to it. A plain `doctor` lists a clone
/// that is still `Booting` as in progress, since a cold boot can take minutes; only `--fix` waits to see.
public struct StuckClonesCheck: DoctorCheck {
    public let id = "stuck-clones"
    static let transient: Set<String> = ["Booting", "Shutting Down", "Creating"]
    /// How long a transient state must last to be reported as stuck.
    public let patience: Duration
    /// How long the fix waits for a stuck clone to settle by itself before shutting it down: longer than xcd's
    /// own `simctl boot` may take, since another agent may be booting it and waiting on it.
    static let settleTimeout = SimctlClient.bootTimeout + .seconds(60)
    static let settlePoll = Duration.seconds(5)

    public init(patience: Duration = .seconds(5)) { self.patience = patience }

    public func detect(_ env: DoctorEnvironment) async -> [DoctorProblem] {
        guard let catalog = env.catalog else { return [] }
        let recorded = env.recordedClones
        let clones = catalog.devices.filter { recorded.contains($0.udid) && Self.busyOwner(of: $0.udid, env) == nil }
        var problems = clones.filter { !$0.isAvailable }.map { device in
            DoctorProblem(check: id, message: "\(device.name) (\(device.udid)) is unavailable; its runtime may have been removed",
                          action: .deleteSimulator, fix: "delete it; it is cloned again on next use", subject: device.udid,
                          projectRoot: Self.recorder(of: device.udid, env)?.projectRoot)
        }
        let settling = clones.filter {
            $0.isAvailable && Self.transient.contains($0.state) && (env.fixing || $0.state != "Booting")
        }
        guard !settling.isEmpty else { return problems }
        try? await env.sleep(patience)
        let later = (try? await env.simctl.catalog()) ?? catalog
        for device in settling {
            guard let now = later.device(udid: device.udid), Self.transient.contains(now.state) else { continue }
            problems.append(DoctorProblem(check: id, message: "\(device.name) (\(device.udid)) is stuck in \(now.state)",
                                          action: .shutDownSimulator,
                                          fix: "if it is still stuck in \(Self.settleMinutes) minutes, shut it down, or delete it if that fails (it is cloned again on next use)",
                                          subject: device.udid, projectRoot: Self.recorder(of: device.udid, env)?.projectRoot))
        }
        return problems
    }

    /// Clones of busy worktrees that would otherwise be problems, and, without `--fix`, clones still booting.
    public func inProgress(_ env: DoctorEnvironment) -> [String] {
        guard let catalog = env.catalog else { return [] }
        let recorded = env.recordedClones
        return catalog.devices.filter { recorded.contains($0.udid) }.compactMap { device in
            let label = "\(device.name) (\(device.udid))"
            if let owner = Self.busyOwner(of: device.udid, env) {
                guard !device.isAvailable || Self.transient.contains(device.state) else { return nil }
                let state = device.isAvailable ? device.state : "unavailable"
                return "\(label) is \(state) while \(owner.project)/\(owner.name) is being created or removed by another xcd; left alone"
            }
            guard !env.fixing, device.isAvailable, device.state == "Booting" else { return nil }
            return "\(label) is Booting, which can take a few minutes; `--fix` shuts it down if it is still booting after \(Self.settleMinutes) minutes"
        }
    }

    static var settleMinutes: Int64 { settleTimeout.components.seconds / 60 }

    /// The worktree recording `udid` whose `wt create` or `wt remove` is running, if any.
    static func busyOwner(of udid: String, _ env: DoctorEnvironment) -> RegistryEntry? {
        env.registry.first { env.isBusy($0) && records($0, udid, env) }
    }

    /// The worktree that records `udid`.
    static func recorder(of udid: String, _ env: DoctorEnvironment) -> RegistryEntry? {
        env.registry.first { records($0, udid, env) }
    }

    static func records(_ entry: RegistryEntry, _ udid: String, _ env: DoctorEnvironment) -> Bool {
        env.states[entry.id]?.devices.values.contains { $0.udid == udid } == true
    }

    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws {
        guard let udid = problem.subject else { return }
        if problem.action == .shutDownSimulator {
            try await waitWhileTransient(udid, env)
            let out = try await env.runner.run(.xcrun(["simctl", "shutdown", udid], developerDir: nil, timeout: .seconds(60)))
            if out.succeeded || out.stderrString.contains("current state: Shutdown") { return }
        }
        try await env.simctl.delete(udid: udid)
        try env.forget(udid: udid)
    }

    /// Polls the clone for up to `settleTimeout`. Returns while it is still transient; throws `DoctorLeftAlone`
    /// if it settled or disappeared meanwhile, so a slow boot is never cut short.
    func waitWhileTransient(_ udid: String, _ env: DoctorEnvironment) async throws {
        var waited = Duration.zero
        while waited < Self.settleTimeout {
            try await env.sleep(Self.settlePoll)
            waited += Self.settlePoll
            guard let device = try await env.simctl.catalog().device(udid: udid) else {
                throw DoctorLeftAlone(note: "\(udid) was deleted meanwhile; left alone")
            }
            if !Self.transient.contains(device.state) {
                throw DoctorLeftAlone(note: "\(device.name) (\(udid)) is now \(device.state); left alone")
            }
        }
    }
}
