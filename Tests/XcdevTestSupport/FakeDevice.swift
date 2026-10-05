import Foundation
import XcdevKit

/// A `DeviceDriving` for unit tests: fixed snapshots, a clock that advances only when the engine pauses, recorded gestures.
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
    /// How many snapshots were asked for, of the app or the system, whether or not they threw.
    public var snapshots = 0
    /// How many of the next snapshots throw before they succeed again.
    public var snapshotsToFail = 0

    /// Every gesture and pasteboard write, in order, e.g. "tap 201,725", "type \"hi\"", "key cmd-\"a\"".
    public var events: [String] = []
    public var pasteboardText: String?
    /// The hardware buttons this device has.
    public var buttons: Set<HardwareButton> = [.home]
    /// Makes every gesture throw.
    public var failGestures = false
    /// Runs after each gesture (e.g. to make the app quit, or the keyboard appear).
    public var onGesture: ((FakeDevice) -> Void)?

    public struct GestureFailure: Error, CustomStringConvertible {
        public var description: String { "gesture failed" }
    }

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
        snapshots += 1
        if snapshotsToFail > 0 {
            snapshotsToFail -= 1
            throw Failure()
        }
        if failSnapshots { throw Failure() }
    }

    public func systemAlert() -> SnapshotNode? { alert }
    public var scale: Double { 3 }
    public var orientation = "portrait"
    public func tap(x: Double, y: Double) throws {
        try gesture("tap \(Self.number(x)),\(Self.number(y))")
        taps.append((x, y))
    }

    public func press(x: Double, y: Double, duration: Double) throws {
        try gesture("press \(Self.number(x)),\(Self.number(y)) \(duration)s")
    }

    public func drag(from: ScreenPoint, to: ScreenPoint, duration: Double) throws {
        try gesture("drag \(Self.number(from.x)),\(Self.number(from.y)) to \(Self.number(to.x)),\(Self.number(to.y)) \(duration)s")
    }

    public func typeText(_ text: String) throws { try gesture("type \(text.debugDescription)") }

    public func pressKey(_ key: String, command: Bool) throws { try gesture("key \(command ? "cmd-" : "")\(key.debugDescription)") }

    public func setPasteboard(text: String) {
        pasteboardText = text
        events.append("pasteboard \(text.debugDescription)")
    }

    public func setPasteboard(image: Data) -> Bool {
        guard image.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return false }       // a PNG's first bytes
        events.append("pasteboard image \(image.count) bytes")
        return true
    }

    public func pressButton(_ button: HardwareButton) throws -> Bool {
        guard buttons.contains(button) else { return false }
        try gesture("button \(button.rawValue)")
        return true
    }

    public func rotate(to orientation: DeviceOrientation) throws {
        try gesture("rotate \(orientation.rawValue)")
        self.orientation = orientation.rawValue
    }

    /// "201" for a whole number, else one decimal.
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func gesture(_ event: String) throws {
        if failGestures { throw GestureFailure() }
        events.append(event)
        onGesture?(self)
    }

    public func pause(_ seconds: Double) {
        clock += seconds
        pauses += 1
        onPause?(self)
    }

    public func now() -> Double { clock }
}
