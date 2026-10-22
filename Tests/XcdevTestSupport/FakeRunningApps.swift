import Synchronization
import XcdevKit

/// Stands in for `NSRunningApplication`: the test sets the running copies of each bundle id, and every bundle id asked
/// for is kept, so a test can say the guard was (or was not) consulted.
public final class FakeRunningApps: MacRunningAppsListing, Sendable {
    private let state = Mutex<(copies: [String: [MacRunningCopy]], queries: [String])>(([:], []))

    public init() { /* nothing runs until a test sets it */ }

    public func set(_ copies: [MacRunningCopy], for bundleId: String) {
        state.withLock { $0.copies[bundleId] = copies }
    }

    /// The bundle ids asked for, in order.
    public var queries: [String] { state.withLock { $0.queries } }

    public func copies(of bundleId: String) -> [MacRunningCopy] {
        state.withLock { state in
            state.queries.append(bundleId)
            return state.copies[bundleId] ?? []
        }
    }
}
