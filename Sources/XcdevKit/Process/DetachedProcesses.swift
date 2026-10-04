import Darwin
import Foundation

public enum DetachedStop: String, Codable, Sendable {
    /// It had already ended (or the record named a different process).
    case notRunning = "not_running"
    /// It ended on the signal.
    case stopped
    /// It didn't end in time and was killed.
    case killed
}

/// Processes that outlive the xcd that started them: screen recordings now, the UI runner later.
public protocol DetachedProcessLaunching: Sendable {
    var inspector: any ProcessInspecting { get }
    /// Starts `invocation` in a session of its own, with stdin from its `inputFile` or /dev/null and stdout and stderr
    /// appended to `log`. Ctrl-C and SIGHUP from the terminal don't reach it, and `Interrupts` doesn't track it.
    /// Returns its identity, read back from the running process.
    func start(_ invocation: Invocation, log: String) throws -> ProcessIdentity
    /// Sends `signal` to its group if `identity` (and `marker`) still match, waits up to `timeout` for it to end,
    /// then kills the group.
    func stop(_ identity: ProcessIdentity, marker: String?, signal: Int32, timeout: Duration) async -> DetachedStop
}

public struct SystemDetachedProcesses: DetachedProcessLaunching {
    public let inspector: any ProcessInspecting
    private let inheritedEnvironment: [String: String]

    public init(inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                inspector: any ProcessInspecting = SystemProcessInspector()) {
        self.inheritedEnvironment = inheritedEnvironment
        self.inspector = inspector
    }

    public func start(_ invocation: Invocation, log: String) throws -> ProcessIdentity {
        let handle = try SystemProcessRunner.appendHandle(for: log)
        defer { try? handle.close() }
        let environment = ContextInfo.childEnvironment(inherited: inheritedEnvironment, overrides: invocation.environment)
        let child: ChildProcess
        do {
            child = try ChildProcess.spawn(invocation.executable, arguments: invocation.arguments, environment: environment,
                                           workingDirectory: invocation.workingDirectory,
                                           stdio: .redirected(output: handle.fileDescriptor, error: handle.fileDescriptor,
                                                              input: invocation.inputFile),
                                           leadsGroup: true, newSession: true)
        } catch {
            throw XcdError(.subprocessFailed, "could not launch \(invocation.executable): \(error.localizedDescription)",
                           details: ["command: \(invocation.commandLine)"])
        }
        // Read before `watch`: until it is reaped the child pins its pid, so this can't be another process's identity.
        let identity = inspector.identity(of: child.pid)
        child.watch(keepZombie: { false })            // reaped if it exits while this xcd still runs, on either path
        guard let identity else {
            throw XcdError(.subprocessFailed, "`\(invocation.argv.prefix(3).joined(separator: " "))` exited as soon as it started",
                           next: "read its output in \(log)", details: ["command: \(invocation.commandLine)"])
        }
        return identity
    }

    public func stop(_ identity: ProcessIdentity, marker: String?, signal: Int32, timeout: Duration) async -> DetachedStop {
        guard inspector.isRunning(identity, marker: marker) else { return .notRunning }
        inspector.signalGroup(identity.pid, signal)
        if await ended(identity, within: timeout) { return .stopped }
        if inspector.isRunning(identity) { inspector.signalGroup(identity.pid, SIGKILL) }
        _ = await ended(identity, within: .seconds(2))
        return .killed
    }

    private func ended(_ identity: ProcessIdentity, within limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            if !inspector.isRunning(identity) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !inspector.isRunning(identity)
    }
}
