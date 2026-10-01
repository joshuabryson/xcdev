import Synchronization
import XcdevKit

/// Reports a process as running for the first `runningChecks` checks, then as gone. `.max` never exits.
public final class FakeProbe: ProcessProbing {
    private let remaining: Mutex<Int>

    public init(runningChecks: Int = .max) { remaining = Mutex(runningChecks) }

    public func isRunning(_ pid: Int32) -> Bool {
        remaining.withLock { left in
            guard left > 0 else { return false }
            if left != .max { left -= 1 }
            return true
        }
    }
}
