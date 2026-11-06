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
        let streams = try Streams(for: invocation)
        defer { try? streams.logHandle?.close() }
        let child = try launch(invocation, stdio: streams.stdio)
        // Only the child writes to the pipes now, so reading them ends when it (and whatever it started) is done.
        try? streams.pipes?.out.fileHandleForWriting.close()
        try? streams.pipes?.err.fileHandleForWriting.close()
        let interrupts = interrupts
        child.watch(keepZombie: { interrupts.fired })

        async let outData = Self.readToEnd(streams.pipes?.out)
        async let errData = Self.readToEnd(streams.pipes?.err)

        // The deadline waits on xcd's own queue, as does the SIGKILL that `terminate` sends after it, so that it fires on
        // time however long the threads that run Swift tasks, or those of the shared queues, are kept busy.
        let timedOut = Flag()
        let deadline = DispatchWorkItem {
            if child.terminate() { timedOut.set() }
        }
        ChildProcess.deadlines.asyncAfter(deadline: .now() + DurationText.seconds(invocation.timeout), execute: deadline)
        let status = await withTaskCancellationHandler {
            await child.wait()
        } onCancel: {
            child.terminate()
        }
        interrupts.finished(child)
        deadline.cancel()
        let (out, err) = await (outData, errData)
        let output = ProcessOutput(exitCode: status, stdoutData: out, stderrData: err)

        if timedOut.isSet { return try Self.stoppedAtDeadline(invocation, output) }
        if Task.isCancelled { throw CancellationError() }
        return output
    }

    /// Starts the child, saying when a missing working directory is why it could not start.
    private func launch(_ invocation: Invocation, stdio: ChildProcess.Stdio) throws -> ChildProcess {
        let environment = ContextInfo.childEnvironment(inherited: inheritedEnvironment, overrides: invocation.environment)
        do {
            return try interrupts.launch(invocation.argv, foreground: invocation.passthrough) {
                try ChildProcess.spawn(invocation.executable, arguments: invocation.arguments, environment: environment,
                                       workingDirectory: invocation.workingDirectory, stdio: stdio,
                                       leadsGroup: !invocation.passthrough)
            }
        } catch let error as XcdError {
            throw error
        } catch {
            var isDirectory: ObjCBool = false
            let reason = invocation.workingDirectory.flatMap { directory in
                FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
                    ? nil : "its working directory \(directory) does not exist"
            } ?? error.localizedDescription
            throw XcdError(.subprocessFailed, "could not launch \(invocation.executable): \(reason)",
                           details: ["command: \(invocation.commandLine)"])
        }
    }

    /// A child its deadline stopped: what it wrote, when the invocation asks for that, or else a `timeout` error.
    private static func stoppedAtDeadline(_ invocation: Invocation, _ output: ProcessOutput) throws -> ProcessOutput {
        guard invocation.stopAtTimeout else {
            var error = XcdError.subprocess(invocation, output, code: .timeout,
                                            message: "`\(invocation.argv.prefix(3).joined(separator: " "))` timed out after \(invocation.timeout)",
                                            next: "re-run with a larger --timeout, or run `xcd doctor` if a simulator is stuck")
            error.details.removeAll { $0.hasPrefix("exit: ") }
            throw error
        }
        var stopped = output
        stopped.stoppedAtDeadline = true
        return stopped
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

/// Where a child's standard streams go: to xcd's own for a passthrough child, to the invocation's output file, or else
/// into pipes that xcd reads.
private struct Streams {
    let pipes: (out: Pipe, err: Pipe)?
    let logHandle: FileHandle?
    let stdio: ChildProcess.Stdio

    init(for invocation: Invocation) throws {
        if invocation.passthrough {
            pipes = nil
            logHandle = nil
            stdio = .shared
        } else if let file = invocation.outputFile {
            let handle = try SystemProcessRunner.appendHandle(for: file)
            logHandle = handle
            pipes = nil
            stdio = .redirected(output: handle.fileDescriptor, error: handle.fileDescriptor,
                                input: invocation.inputFile)
        } else {
            let captured = (out: Pipe(), err: Pipe())
            pipes = captured
            logHandle = nil
            stdio = .redirected(output: captured.out.fileHandleForWriting.fileDescriptor,
                                error: captured.err.fileHandleForWriting.fileDescriptor,
                                input: invocation.inputFile)
        }
    }
}

private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}
