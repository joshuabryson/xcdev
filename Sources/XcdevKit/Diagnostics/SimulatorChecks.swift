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
                              action: .restartCoreSimulator, fix: "restart the CoreSimulator service (booted simulators shut down)",
                              next: "if it still fails, quit Simulator.app and Xcode, or restart the Mac")]
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
    /// timed out (the service is hung), or when its stderr names CoreSimulator, its device set, or a broken
    /// connection to the service (e.g. "Failed to initialize simulator device set.", "CoreSimulatorService
    /// connection became invalid", NSMachErrorDomain errors). False when xcrun itself failed ("xcrun: error:",
    /// e.g. no Xcode selected), when simctl exited without saying why, or when its output couldn't be parsed:
    /// a restart wouldn't fix those, and it would shut down every simulator on the Mac.
    static func isCoreSimulatorFailure(_ error: XcdError) -> Bool {
        if error.code == .timeout { return true }
        let stderr = error.details.filter { !$0.hasPrefix("command: ") && !$0.hasPrefix("exit: ") }
            .joined(separator: "\n").lowercased()
        if stderr.contains("xcrun: error:") { return false }
        let markers = ["coresimulator", "device set", "nsmacherrordomain", "mach error", "connection"]
        return markers.contains { stderr.contains($0) }
    }
}

/// Templates must be available, shut down, and unique; missing ones are simply re-created on next use.
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
                problems.append(DoctorProblem(check: id, message: "\(label) is a duplicate template", action: .deleteSimulator,
                                              fix: "delete it", subject: template.udid))
            } else if !template.isAvailable {
                problems.append(DoctorProblem(check: id, message: "\(label) is unavailable; its runtime may have been removed",
                                              action: .deleteSimulator, fix: "delete it; it is re-created when next needed",
                                              subject: template.udid))
            } else if template.state != "Shutdown" {
                problems.append(DoctorProblem(check: id, message: "\(label) is \(template.state); clones need a shut-down template",
                                              action: .shutDownSimulator, fix: "shut it down", subject: template.udid))
            }
        }
        return problems
    }

    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws {
        guard let udid = problem.subject else { return }
        if problem.action == .shutDownSimulator {
            try await env.simctl.shutdown(udid: udid)
        } else {
            try await env.simctl.delete(udid: udid)
        }
    }
}
