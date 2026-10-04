import Foundation
import Synchronization
import XcdevKit

/// Records detached starts and stops instead of running anything. Started processes "run" until stopped or `exit`ed.
public final class FakeDetachedProcesses: DetachedProcessLaunching {
    public struct Start: Sendable {
        public let invocation: Invocation
        public let log: String
        public let identity: ProcessIdentity
    }

    public struct Stop: Sendable, Equatable {
        public let pid: Int32
        public let signal: Int32

        public init(pid: Int32, signal: Int32) {
            self.pid = pid
            self.signal = signal
        }
    }

    private struct State {
        var starts: [Start] = []
        var stops: [Stop] = []
        var running: [Int32: ProcessIdentity] = [:]
        var nextPid: Int32 = 50_000
    }

    private let state = Mutex(State())
    private let onStart: @Sendable (Invocation, String) throws -> Void
    private let stopResult: DetachedStop
    private let onStop: @Sendable (Stop) -> Void

    /// `onStart` runs before the process "starts" (write its log, or throw to fail the start). `stopResult` is what a
    /// stop of a running process returns; `onStop` sees each signal sent.
    public init(onStart: @escaping @Sendable (Invocation, String) throws -> Void = { _, _ in },
                stopResult: DetachedStop = .stopped, onStop: @escaping @Sendable (Stop) -> Void = { _ in }) {
        self.onStart = onStart
        self.stopResult = stopResult
        self.onStop = onStop
    }

    public var starts: [Start] { state.withLock { $0.starts } }
    public var stops: [Stop] { state.withLock { $0.stops } }
    public var inspector: any ProcessInspecting { Inspector(fake: self) }

    /// Makes `identity` a running process, as if another xcd had started it.
    public func adopt(_ identity: ProcessIdentity) { state.withLock { $0.running[identity.pid] = identity } }
    /// Makes `pid` exit on its own.
    public func exit(pid: Int32) { _ = state.withLock { $0.running.removeValue(forKey: pid) } }

    public func start(_ invocation: Invocation, log: String) throws -> ProcessIdentity {
        try onStart(invocation, log)
        return state.withLock { st in
            st.nextPid += 1
            let identity = ProcessIdentity(pid: st.nextPid, startTime: 1_791_030_000 + Double(st.nextPid),
                                           arguments: invocation.argv)
            st.running[identity.pid] = identity
            st.starts.append(Start(invocation: invocation, log: log, identity: identity))
            return identity
        }
    }

    public func stop(_ identity: ProcessIdentity, marker: String?, signal: Int32, timeout: Duration) async -> DetachedStop {
        guard inspector.isRunning(identity, marker: marker) else { return .notRunning }
        let stop = Stop(pid: identity.pid, signal: signal)
        state.withLock { st in
            st.stops.append(stop)
            st.running[identity.pid] = nil
        }
        onStop(stop)
        return stopResult
    }

    struct Inspector: ProcessInspecting {
        let fake: FakeDetachedProcesses
        func identity(of pid: Int32) -> ProcessIdentity? { fake.state.withLock { $0.running[pid] } }
        func signalGroup(_ pid: Int32, _ signal: Int32) -> Bool { identity(of: pid) != nil }
    }
}
