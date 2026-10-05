import UIKit
import XCTest

/// `DeviceDriving` on XCUITest. Every method must be called on the main thread: a gesture off it kills the runner.
/// It never launches, activates, or terminates an app.
final class XCUIDriver: DeviceDriving {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let hardware = XCUIDevice.shared
    private var apps: [String: XCUIApplication] = [:]
    /// The app last read, whose coordinate space taps use while it is in front.
    private var current: XCUIApplication?

    private func app(_ bundleId: String) -> XCUIApplication {
        if let app = apps[bundleId] { return app }
        let app = XCUIApplication(bundleIdentifier: bundleId)
        apps[bundleId] = app
        return app
    }

    func appState(_ bundleId: String) -> AppRunState {
        switch app(bundleId).state {
        case .runningForeground: return .foreground
        case .runningBackground, .runningBackgroundSuspended: return .background
        default: return .notRunning
        }
    }

    func appSnapshot(_ bundleId: String) throws -> SnapshotNode {
        let app = app(bundleId)
        let node = Self.node(try app.snapshot())
        current = app
        return node
    }

    func systemSnapshot() throws -> SnapshotNode {
        current = nil
        return Self.node(try springboard.snapshot())
    }

    func systemAlert() -> SnapshotNode? {
        let alert = springboard.alerts.firstMatch
        guard alert.exists, let snapshot = try? alert.snapshot() else { return nil }
        return Self.node(snapshot)
    }

    var scale: Double { Double(UIScreen.main.scale) }

    var orientation: String {
        switch hardware.orientation {
        case .landscapeLeft: return "landscape-left"
        case .landscapeRight: return "landscape-right"
        case .portraitUpsideDown: return "portrait-upside-down"
        default: return "portrait"
        }
    }

    /// The app last read while it is in front; else Springboard. Gestures and keys go to it.
    private var front: XCUIApplication {
        if let current, current.state == .runningForeground { return current }
        return springboard
    }

    /// Frames are screen points. A coordinate is relative to an element, so the offset is taken from that element's
    /// own origin: the app in front (which may not start at 0,0 in iPad split view), else Springboard.
    private func coordinate(x: Double, y: Double) -> XCUICoordinate {
        let base = front
        let origin = base.frame.origin
        return base.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - Double(origin.x), dy: y - Double(origin.y)))
    }

    func tap(x: Double, y: Double) throws { coordinate(x: x, y: y).tap() }

    func press(x: Double, y: Double, duration: Double) throws { coordinate(x: x, y: y).press(forDuration: duration) }

    /// A short press, then a drag at the speed that covers the distance in `duration`.
    func drag(from: ScreenPoint, to: ScreenPoint, duration: Double) throws {
        let distance = hypot(to.x - from.x, to.y - from.y)
        let velocity = XCUIGestureVelocity(CGFloat(distance / max(duration, 0.05)))
        coordinate(x: from.x, y: from.y).press(forDuration: 0.05, thenDragTo: coordinate(x: to.x, y: to.y), withVelocity: velocity,
                                               thenHoldForDuration: 0)
    }

    func typeText(_ text: String) throws { front.typeText(text) }

    func pressKey(_ key: String, command: Bool) throws { front.typeKey(key, modifierFlags: command ? .command : []) }

    /// Setting the pasteboard shows no prompt; only reading what another process wrote does.
    func setPasteboard(text: String) { UIPasteboard.general.string = text }

    func setPasteboard(image: Data) -> Bool {
        guard let image = UIImage(data: image) else { return false }
        UIPasteboard.general.image = image
        return UIPasteboard.general.hasImages
    }

    func pressButton(_ button: HardwareButton) throws -> Bool {
        let key: XCUIDevice.Button
        switch button {
        case .home: key = .home
        case .action: key = .action
        case .camera: key = .camera
        }
        guard hardware.hasHardwareButton(key) else { return false }
        hardware.press(key)
        return true
    }

    func rotate(to orientation: DeviceOrientation) throws {
        switch orientation {
        case .portrait: hardware.orientation = .portrait
        case .portraitUpsideDown: hardware.orientation = .portraitUpsideDown
        case .landscapeLeft: hardware.orientation = .landscapeLeft
        case .landscapeRight: hardware.orientation = .landscapeRight
        }
    }

    /// Waits by running the main run loop, not by sleeping. XCUITest learns that an app changed state through the run
    /// loop, so a sleeping thread keeps seeing the old state for the whole request (seen: an app sent to the
    /// background by Home stayed "in front" through two seconds of sleeping, and its snapshot then hung).
    func pause(_ seconds: Double) {
        let end = now() + seconds
        while now() < end {
            // With nothing to wait on, the run loop returns at once: sleep a little so this doesn't spin.
            if CFRunLoopRunInMode(.defaultMode, end - now(), false) == .finished { Thread.sleep(forTimeInterval: 0.01) }
        }
    }

    /// Monotonic, so a clock change can't stretch or cut a wait.
    func now() -> Double { ProcessInfo.processInfo.systemUptime }

    static func node(_ snapshot: XCUIElementSnapshot) -> SnapshotNode {
        SnapshotNode(elementType: Int(snapshot.elementType.rawValue), identifier: snapshot.identifier, label: snapshot.label,
                     value: snapshot.value.map { "\($0)" }, placeholder: snapshot.placeholderValue,
                     frame: ScreenRect(x: Double(snapshot.frame.minX), y: Double(snapshot.frame.minY),
                                       w: Double(snapshot.frame.width), h: Double(snapshot.frame.height)),
                     enabled: snapshot.isEnabled, selected: snapshot.isSelected, children: snapshot.children.map(node),
                     focused: keyboardFocus(snapshot))
    }

    /// The attribute XCTest's own typing check reads. It is not in the public headers, so it is asked for by name.
    private static let keyboardFocusKey = "hasKeyboardFocus"

    /// Whether the element has keyboard focus. The public `hasFocus` is no use here: it stays false on a text field
    /// that is being typed into (seen on iOS 27.0, where this attribute was true on exactly that field). Nil when
    /// this Xcode's snapshots don't answer to the name, and the engine then acts as if it had never asked.
    static func keyboardFocus(_ snapshot: XCUIElementSnapshot) -> Bool? {
        guard let object = snapshot as? NSObject, object.responds(to: NSSelectorFromString(keyboardFocusKey)) else { return nil }
        return object.value(forKey: keyboardFocusKey) as? Bool
    }

    /// Whether `ElementRole`'s numbers match this Xcode's element types.
    static var rolesVerified: Bool {
        let expected: [(XCUIElement.ElementType, String)] = [
            (.application, "application"), (.window, "window"), (.alert, "alert"), (.button, "button"), (.keyboard, "keyboard"),
            (.key, "key"), (.switch, "switch"), (.link, "link"), (.image, "image"), (.searchField, "searchField"),
            (.staticText, "text"), (.textField, "textField"), (.secureTextField, "secureTextField"), (.textView, "textView"),
            (.cell, "cell"), (.tab, "tab"), (.other, "other"),
        ]
        return expected.allSatisfy { ElementRole.name(for: Int($0.0.rawValue)) == $0.1 }
    }
}
