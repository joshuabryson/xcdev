import Foundation
import Synchronization

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ invocation: Invocation) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(invocation.environment) { $1 }
        if let directory = invocation.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let exit = ExitSignal()
        process.terminationHandler = { exit.finish($0.terminationStatus) }
        do {
            try process.run()
        } catch {
            throw XcdError(.subprocessFailed,
                           "could not launch \(invocation.executable): \(error.localizedDescription)",
                           details: ["command: \(invocation.commandLine)"])
        }

        let handle = ProcessHandle(process)
        async let outData = Self.readToEnd(stdout.fileHandleForReading)
        async let errData = Self.readToEnd(stderr.fileHandleForReading)

        let timedOut = Flag()
        let timer = Task {
            try? await Task.sleep(for: invocation.timeout)
            guard !Task.isCancelled else { return }
            if handle.terminate() { timedOut.set() }
        }
        let status = await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            _ = handle.terminate()
        }
        timer.cancel()
        let (out, err) = await (outData, errData)

        if timedOut.isSet {
            let output = ProcessOutput(exitCode: status, stdoutData: out, stderrData: err)
            var error = XcdError.subprocess(invocation, output, code: .timeout,
                                            message: "`\(invocation.argv.prefix(3).joined(separator: " "))` timed out after \(invocation.timeout)",
                                            next: "re-run with a larger --timeout, or run `xcd doctor` if a simulator is stuck")
            error.details.removeAll { $0.hasPrefix("exit: ") }
            throw error
        }
        if Task.isCancelled { throw CancellationError() }
        return ProcessOutput(exitCode: status, stdoutData: out, stderrData: err)
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }
}

private final class ProcessHandle: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    /// Sends SIGTERM, then SIGKILL after a grace period if the process is still running.
    /// Returns whether a running process was signalled.
    @discardableResult
    func terminate() -> Bool {
        guard process.isRunning else { return false }
        process.terminate()
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        return true
    }
}

private final class ExitSignal: Sendable {
    private let state = Mutex<(status: Int32?, waiters: [CheckedContinuation<Int32, Never>])>((nil, []))

    func finish(_ status: Int32) {
        let waiters = state.withLock { state in
            state.status = status
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume(returning: status) }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let ready: Int32? = state.withLock { state in
                if let status = state.status { return status }
                state.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}
