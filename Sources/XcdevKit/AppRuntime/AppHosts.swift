import Foundation

public enum AppEnvironment {
    /// Makes `print` output reach the log file as it happens, and mirrors os_log/Logger lines to stderr.
    public static let captureOutput = ["NSUnbufferedIO": "YES", "OS_ACTIVITY_DT_MODE": "YES"]
}

/// Where an app is installed and run: a simulator clone, or this Mac.
public protocol AppHost: Sendable {
    func install(_ product: AppProduct) async throws
    func uninstall(_ product: AppProduct) async throws
    /// Starts the app with stdout and stderr going to `logFile`; returns its pid.
    func launch(_ product: AppProduct, arguments: [String], environment: [String: String], logFile: String) async throws -> Int32
    /// Stops the app; false when it wasn't running.
    func terminate(_ product: AppProduct) async throws -> Bool
}

public struct SimulatorAppHost: AppHost {
    public let simctl: SimctlClient
    public let udid: String

    public init(simctl: SimctlClient, udid: String) {
        self.simctl = simctl
        self.udid = udid
    }

    public func install(_ product: AppProduct) async throws {
        try await simctl.install(udid: udid, appPath: product.path)
    }

    public func uninstall(_ product: AppProduct) async throws {
        try await simctl.uninstall(udid: udid, bundleId: product.bundleId)
    }

    public func launch(_ product: AppProduct, arguments: [String], environment: [String: String],
                       logFile: String) async throws -> Int32 {
        try await simctl.launch(udid: udid, bundleId: product.bundleId, arguments: arguments, environment: environment,
                                logFile: logFile)
    }

    public func terminate(_ product: AppProduct) async throws -> Bool {
        try await simctl.terminate(udid: udid, bundleId: product.bundleId)
    }
}

/// Runs a macOS app straight from this worktree's DerivedData. Nothing is installed.
public struct MacAppHost: AppHost {
    public let runner: any ProcessRunning
    let sleep: @Sendable (Duration) async throws -> Void

    public init(runner: any ProcessRunning,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.runner = runner
        self.sleep = sleep
    }

    public func install(_ product: AppProduct) async throws {}
    public func uninstall(_ product: AppProduct) async throws {}

    public func launch(_ product: AppProduct, arguments: [String], environment: [String: String],
                       logFile: String) async throws -> Int32 {
        let before = try await pids(of: product.executablePath)
        var args = ["-n", "-g", "--stdout", logFile, "--stderr", logFile]
        let env = AppEnvironment.captureOutput.merging(environment, uniquingKeysWith: { $1 })
        for (key, value) in env.sorted(by: { $0.key < $1.key }) { args += ["--env", "\(key)=\(value)"] }
        args.append(product.path)
        if !arguments.isEmpty { args += ["--args"] + arguments }
        try await runner.runChecked(Invocation("/usr/bin/open", args), next: "read the app log: \(logFile)")
        for _ in 0..<20 {
            if let pid = try await pids(of: product.executablePath).subtracting(before).max() { return pid }
            try await sleep(.milliseconds(250))
        }
        throw XcdError(.subprocessFailed, "\(product.executableName) did not start within 5s",
                       next: "read the app log: \(logFile)")
    }

    public func terminate(_ product: AppProduct) async throws -> Bool {
        let running = try await pids(of: product.executablePath).sorted()
        for pid in running {
            _ = try await runner.run(Invocation("/bin/kill", ["-TERM", String(pid)]))
        }
        return !running.isEmpty
    }

    /// Pids whose executable is exactly `path`. `ps -o comm` prints the full executable path on macOS.
    func pids(of path: String) async throws -> Set<Int32> {
        let out = try await runner.runChecked(Invocation("/bin/ps", ["-axo", "pid=,comm="], timeout: .seconds(10)))
        var pids = Set<Int32>()
        for line in out.stdoutString.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]),
                  trimmed[trimmed.index(after: space)...] == Substring(path) else { continue }
            pids.insert(pid)
        }
        return pids
    }
}
