import Foundation

public protocol ProcessProbing: Sendable {
    func isRunning(_ pid: Int32) -> Bool
}

public struct SystemProcessProbe: ProcessProbing {
    public init() {}

    /// Signal 0 checks existence without sending anything. EPERM means it exists but isn't ours.
    public func isRunning(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}

public enum LaunchOutcome: Sendable, Equatable {
    case running
    /// The process ended `after` seconds into the window; `crash` is its report, if one appeared.
    case exited(after: Double, crash: CrashReport?)
}

/// Watches a freshly launched app for the crash window, then looks for its crash report.
public struct CrashWatcher: Sendable {
    public let probe: any ProcessProbing
    public let locator: CrashReportLocator
    public let pollInterval: Duration
    public let reportWait: Duration
    let sleep: @Sendable (Duration) async throws -> Void

    public init(probe: any ProcessProbing, locator: CrashReportLocator, pollInterval: Duration = .milliseconds(250),
                reportWait: Duration = .seconds(10),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.probe = probe
        self.locator = locator
        self.pollInterval = pollInterval
        self.reportWait = reportWait
        self.sleep = sleep
    }

    public func watch(pid: Int32, processName: String, window: Duration, launchedAt: Date) async throws -> LaunchOutcome {
        var elapsed = Duration.zero
        while true {
            if !probe.isRunning(pid) {
                let crash = try await report(processName: processName, pid: pid, since: launchedAt)
                return .exited(after: DurationText.seconds(elapsed), crash: crash)
            }
            if elapsed >= window { return .running }
            try await sleep(pollInterval)
            elapsed += pollInterval
        }
    }

    /// Crash reports appear a second or two after the process dies. A nil `pid` takes any report for `processName`.
    func report(processName: String, pid: Int32?, since: Date) async throws -> CrashReport? {
        var waited = Duration.zero
        while true {
            if let report = locator.find(processName: processName, pid: pid, since: since) { return report }
            if waited >= reportWait { return nil }
            try await sleep(pollInterval)
            waited += pollInterval
        }
    }
}
