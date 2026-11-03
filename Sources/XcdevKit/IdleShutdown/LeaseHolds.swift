import Foundation
import Synchronization

/// This process's shared holds on `lease.lock`, one per clone, kept until the process exits (or `release`). A
/// watchdog that finds the lock held leaves the clone alone, so a command holds it for as long as it runs.
public final class LeaseHolds: Sendable {
    public static let shared = LeaseHolds()

    private let held = Mutex<[String: Int32]>([:])

    public init() {}

    /// Takes a shared hold on `lockPath` for `udid`; nothing happens when this process already holds that clone.
    public func hold(_ udid: String, at lockPath: String) async throws {
        if isHolding(udid) { return }
        let descriptor = try await FileLock.hold(at: lockPath)
        let added = held.withLock { map -> Bool in
            guard map[udid] == nil else { return false }
            map[udid] = descriptor
            return true
        }
        if !added { FileLock.release(descriptor) }
    }

    public func release(_ udid: String) {
        let descriptor = held.withLock { $0.removeValue(forKey: udid) }
        if let descriptor { FileLock.release(descriptor) }
    }

    public func isHolding(_ udid: String) -> Bool {
        held.withLock { $0[udid] != nil }
    }
}
