import Foundation
import Synchronization

public struct SystemProcessRunner: ProcessRunning {
    /// The environment children inherit, before each invocation's own is merged over it.
    private let inheritedEnvironment: [String: String]
    /// Tracks the children for the SIGINT/SIGTERM handler, and stops a passthrough child's Ctrl-C reaching xcd.
    private let interrupts: Interrupts

    public init(inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                interrupts: Interrupts = .shared) {
        self.inheritedEnvironment = inheritedEnvironment
        self.interrupts = interrupts
    }

    /// A passthrough child runs in xcd's process group, so it can read the terminal and gets its Ctrl-C; every other
    /// child leads a group of its own, out of the terminal's reach, which `Interrupts` stops on SIGINT or SIGTERM.
    public func run(_ invocation: Invocation) async throws -> ProcessOutput {
        let environment = ContextInfo.childEnvironment(inherited: inheritedEnvironment, overrides: invocation.environment)
        let pipes: (out: Pipe, err: Pipe)?
        let logHandle: FileHandle?
        let stdio: ChildProcess.Stdio
        if invocation.passthrough {
            pipes = nil
            logHandle = nil
            stdio = .shared
        } else if let file = invocation.outputFile {
            let handle = try Self.appendHandle(for: file)
            logHandle = handle
            pipes = nil
            stdio = .redirected(output: handle.fileDescriptor, error: handle.fileDescriptor)
        } else {
            let captured = (out: Pipe(), err: Pipe())
            pipes = captured
            logHandle = nil
            stdio = .redirected(output: captured.out.fileHandleForWriting.fileDescriptor,
                                error: captured.err.fileHandleForWriting.fileDescriptor)
        }
        defer { try? logHandle?.close() }

        let child: ChildProcess
        do {
            child = try interrupts.launch(invocation.argv, foreground: invocation.passthrough) {
                try ChildProcess.spawn(invocation.executable, arguments: invocation.arguments, environment: environment,
                                       workingDirectory: invocation.workingDirectory, stdio: stdio,
                                       leadsGroup: !invocation.passthrough)
            }
        } catch let error as XcdError {
            throw error
        } catch {
            throw XcdError(.subprocessFailed,
                           "could not launch \(invocation.executable): \(error.localizedDescription)",
                           details: ["command: \(invocation.commandLine)"])
        }
        // Only the child writes to the pipes now, so reading them ends when it (and whatever it started) is done.
        try? pipes?.out.fileHandleForWriting.close()
        try? pipes?.err.fileHandleForWriting.close()
        let interrupts = interrupts
        child.watch(keepZombie: { interrupts.fired })

        async let outData = Self.readToEnd(pipes?.out)
        async let errData = Self.readToEnd(pipes?.err)

        let timedOut = Flag()
        let timer = Task {
            try? await Task.sleep(for: invocation.timeout)
            guard !Task.isCancelled else { return }
            if child.terminate() { timedOut.set() }
        }
        let status = await withTaskCancellationHandler {
            await child.wait()
        } onCancel: {
            child.terminate()
        }
        interrupts.finished(child)
        timer.cancel()
        let (out, err) = await (outData, errData)

        if timedOut.isSet {
            var output = ProcessOutput(exitCode: status, stdoutData: out, stderrData: err)
            if invocation.stopAtTimeout {
                output.stoppedAtDeadline = true
                return output
            }
            var error = XcdError.subprocess(invocation, output, code: .timeout,
                                            message: "`\(invocation.argv.prefix(3).joined(separator: " "))` timed out after \(invocation.timeout)",
                                            next: "re-run with a larger --timeout, or run `xcd doctor` if a simulator is stuck")
            error.details.removeAll { $0.hasPrefix("exit: ") }
            throw error
        }
        if Task.isCancelled { throw CancellationError() }
        return ProcessOutput(exitCode: status, stdoutData: out, stderrData: err)
    }

    private static func readToEnd(_ pipe: Pipe?) async -> Data {
        guard let handle = pipe?.fileHandleForReading else { return Data() }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }

    /// Opens `file` for appending, creating it and its parent directories. Shared with the fake runner.
    package static func appendHandle(for file: String) throws -> FileHandle {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file) { fm.createFile(atPath: file, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: file) else {
            throw XcdError(.internalError, "cannot write \(file)")
        }
        handle.seekToEndOfFile()
        return handle
    }
}

private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}
