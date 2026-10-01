import Foundation
import Synchronization
import XcdevKit

/// Replays canned output for invocations matched by argv prefix. Later stubs win.
public final class FakeProcessRunner: ProcessRunning {
    public typealias Responder = @Sendable (Invocation) throws -> ProcessOutput

    private struct Stub: Sendable {
        let prefix: [String]
        let respond: Responder
    }

    private let state = Mutex<(stubs: [Stub], calls: [Invocation])>(([], []))

    public init() {}

    public func stub(_ prefix: [String], exitCode: Int32 = 0, stdout: String = "", stderr: String = "") {
        stub(prefix) { _ in ProcessOutput(exitCode: exitCode, stdout: stdout, stderr: stderr) }
    }

    public func stub(_ prefix: [String], respond: @escaping Responder) {
        state.withLock { $0.stubs.append(Stub(prefix: prefix, respond: respond)) }
    }

    public var calls: [Invocation] { state.withLock { $0.calls } }
    public var commandLines: [String] { calls.map(\.commandLine) }

    public func run(_ invocation: Invocation) async throws -> ProcessOutput {
        let stub = state.withLock { state -> Stub? in
            state.calls.append(invocation)
            return state.stubs.last { invocation.argv.starts(with: $0.prefix) }
        }
        guard let stub else {
            throw XcdError(.internalError, "unstubbed command: \(invocation.commandLine)")
        }
        return try stub.respond(invocation)
    }
}

/// Runs listed executables (by basename, e.g. "git", "cp") for real and everything else on the fake.
public struct RoutingRunner: ProcessRunning {
    public let fake: FakeProcessRunner
    public let realExecutables: Set<String>
    private let real = SystemProcessRunner()

    public init(fake: FakeProcessRunner, realExecutables: Set<String> = ["git", "cp"]) {
        self.fake = fake
        self.realExecutables = realExecutables
    }

    public func run(_ invocation: Invocation) async throws -> ProcessOutput {
        if realExecutables.contains(invocation.argv[0]) { return try await real.run(invocation) }
        return try await fake.run(invocation)
    }
}

public final class Counter: Sendable {
    private let count = Mutex(0)
    public init() {}
    @discardableResult public func increment() -> Int { count.withLock { $0 += 1; return $0 } }
    @discardableResult public func decrement() -> Int { count.withLock { $0 -= 1; return $0 } }
    public var value: Int { count.withLock { $0 } }
}
