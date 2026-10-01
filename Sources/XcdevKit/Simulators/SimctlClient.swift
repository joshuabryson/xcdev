import Foundation

public struct SimctlClient: Sendable {
    public let runner: any ProcessRunning
    public let developerDir: String?
    let sleep: @Sendable (Duration) async throws -> Void

    public init(runner: any ProcessRunning, developerDir: String?,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.runner = runner
        self.developerDir = developerDir
        self.sleep = sleep
    }

    public func catalog() async throws -> SimCatalog {
        let out = try await runner.runChecked(simctl(["list", "-j"]), code: .simulatorFailed, next: "run `xcd doctor`")
        return try SimCatalog.decode(out.stdout)
    }

    public func create(name: String, type: SimDeviceType, runtime: SimRuntime) async throws -> String {
        let out = try await runner.runChecked(simctl(["create", name, type.identifier, runtime.identifier]),
                                              code: .cloneFailed, next: "run `xcd doctor`")
        return out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func clone(udid: String, name: String) async throws -> String {
        let out = try await runner.runChecked(simctl(["clone", udid, name], timeout: .seconds(180)),
                                              code: .cloneFailed, next: "run `xcd doctor`")
        return out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Boots and waits until the device has finished booting. Returns how many transient-state retries happened.
    @discardableResult
    public func boot(udid: String) async throws -> Int {
        let retries = try await retrying(["boot", udid], alreadyDone: "current state: Booted", timeout: .seconds(180))
        try await runner.runChecked(simctl(["bootstatus", udid, "-b"], timeout: .seconds(300)),
                                    code: .simulatorFailed, next: "run `xcd doctor`")
        return retries
    }

    @discardableResult
    public func shutdown(udid: String) async throws -> Int {
        try await retrying(["shutdown", udid], alreadyDone: "current state: Shutdown")
    }

    public func erase(udid: String) async throws {
        try await runner.runChecked(simctl(["erase", udid]), code: .simulatorFailed, next: "run `xcd doctor`")
    }

    /// Deleting a device that no longer exists is not an error.
    public func delete(udid: String) async throws {
        let invocation = simctl(["delete", udid])
        let out = try await runner.run(invocation)
        guard out.succeeded || out.stderrString.contains("Invalid device") else {
            throw XcdError.subprocess(invocation, out, code: .simulatorFailed, next: "run `xcd doctor`")
        }
    }

    public func pair(watch: String, phone: String) async throws {
        try await runner.runChecked(simctl(["pair", watch, phone]), code: .cloneFailed, next: "run `xcd doctor`")
    }

    public func openSimulatorApp(udid: String) async throws {
        try await runner.runChecked(Invocation("/usr/bin/open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid]))
    }

    public func install(udid: String, appPath: String) async throws {
        try await runner.runChecked(simctl(["install", udid, appPath], timeout: .seconds(300)), code: .simulatorFailed,
                                    next: "boot the simulator with `xcd sim boot`, or rebuild with `xcd build`")
    }

    public func uninstall(udid: String, bundleId: String) async throws {
        try await runner.runChecked(simctl(["uninstall", udid, bundleId]), code: .simulatorFailed, next: "run `xcd doctor`")
    }

    /// Launches the app, replacing a running copy, and returns its (host) pid. stdout and stderr both go to
    /// `logFile`. `environment` reaches the app through simctl's SIMCTL_CHILD_ prefix.
    public func launch(udid: String, bundleId: String, arguments: [String], environment: [String: String],
                       logFile: String) async throws -> Int32 {
        var invocation = simctl(["launch", "--terminate-running-process", "--stdout=\(logFile)", "--stderr=\(logFile)",
                                 udid, bundleId] + arguments)
        for (key, value) in AppEnvironment.captureOutput.merging(environment, uniquingKeysWith: { $1 }) {
            invocation.environment["SIMCTL_CHILD_" + key] = value
        }
        let out = try await runner.runChecked(invocation, code: .simulatorFailed,
                                              next: "install the app with `xcd install` (or use `xcd run`), then retry")
        let text = out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.split(separator: ":").last, let pid = Int32(last.trimmingCharacters(in: .whitespaces)) else {
            throw XcdError(.simulatorFailed, "could not read the pid from `simctl launch` output", details: [text])
        }
        return pid
    }

    /// Returns false when the app wasn't running (or the simulator is shut down).
    public func terminate(udid: String, bundleId: String) async throws -> Bool {
        let invocation = simctl(["terminate", udid, bundleId])
        let out = try await runner.run(invocation)
        if out.succeeded { return true }
        if out.stderrString.contains("found nothing to terminate") || out.stderrString.contains("current state: Shutdown") {
            return false
        }
        throw XcdError.subprocess(invocation, out, code: .simulatorFailed, next: "run `xcd doctor`")
    }

    private func simctl(_ args: [String], timeout: Duration = .seconds(60)) -> Invocation {
        .xcrun(["simctl"] + args, developerDir: developerDir, timeout: timeout)
    }

    private static let transientStates = ["current state: Booting", "current state: Shutting Down", "current state: Creating"]

    private func retrying(_ args: [String], alreadyDone: String, timeout: Duration = .seconds(60)) async throws -> Int {
        var retries = 0
        while true {
            let invocation = simctl(args, timeout: timeout)
            let out = try await runner.run(invocation)
            if out.succeeded || out.stderrString.contains(alreadyDone) { return retries }
            let transient = Self.transientStates.contains { out.stderrString.contains($0) }
            guard transient, retries < 3 else {
                throw XcdError.subprocess(invocation, out, code: .simulatorFailed, next: "run `xcd doctor`")
            }
            retries += 1
            try await sleep(.seconds(1 << retries))
        }
    }
}
