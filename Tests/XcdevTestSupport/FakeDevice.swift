import Foundation
import XcdevKit

/// A `DeviceDriving` for unit tests: fixed snapshots, a clock that advances only when the engine pauses, recorded taps.
public final class FakeDevice: DeviceDriving {
    public var state: AppRunState = .foreground
    public var app: SnapshotNode?
    public var system: SnapshotNode
    public var alert: SnapshotNode?
    public var taps: [(x: Double, y: Double)] = []
    public var clock: Double = 0
    public var pauses = 0
    /// Runs after each pause (e.g. to make an element appear after a few polls).
    public var onPause: ((FakeDevice) -> Void)?
    public var failSnapshots = false
    /// How many of the next snapshots throw before they succeed again.
    public var snapshotsToFail = 0

    public init(app: SnapshotNode?, system: SnapshotNode) {
        self.app = app
        self.system = system
    }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String { "snapshot failed" }
    }

    public func appState(_ bundleId: String) -> AppRunState { state }

    public func appSnapshot(_ bundleId: String) throws -> SnapshotNode {
        try failIfAsked()
        guard let app else { throw Failure() }
        return app
    }

    public func systemSnapshot() throws -> SnapshotNode {
        try failIfAsked()
        return system
    }

    private func failIfAsked() throws {
        if snapshotsToFail > 0 {
            snapshotsToFail -= 1
            throw Failure()
        }
        if failSnapshots { throw Failure() }
    }

    public func systemAlert() -> SnapshotNode? { alert }
    public var scale: Double { 3 }
    public var orientation: String { "portrait" }
    public func tap(x: Double, y: Double) throws { taps.append((x, y)) }

    public func pause(_ seconds: Double) {
        clock += seconds
        pauses += 1
        onPause?(self)
    }

    public func now() -> Double { clock }
}
