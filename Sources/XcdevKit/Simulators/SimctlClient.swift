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
