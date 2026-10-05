import UIKit
import XCTest

/// `DeviceDriving` on XCUITest. Every method must be called on the main thread: a gesture off it kills the runner.
/// It never launches, activates, or terminates an app.
final class XCUIDriver: DeviceDriving {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
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
        switch XCUIDevice.shared.orientation {
        case .landscapeLeft: return "landscape-left"
        case .landscapeRight: return "landscape-right"
        case .portraitUpsideDown: return "portrait-upside-down"
        default: return "portrait"
        }
    }

    /// Frames are screen points. A coordinate is relative to an element, so the offset is taken from that element's
    /// own origin: the app in front (which may not start at 0,0 in iPad split view), else Springboard.
    func tap(x: Double, y: Double) throws {
        let base: XCUIApplication
        if let current, current.state == .runningForeground {
            base = current
        } else {
            base = springboard
        }
        let origin = base.frame.origin
        base.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x - Double(origin.x), dy: y - Double(origin.y))).tap()
    }

    func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    /// Monotonic, so a clock change can't stretch or cut a wait.
    func now() -> Double { ProcessInfo.processInfo.systemUptime }

    static func node(_ snapshot: XCUIElementSnapshot) -> SnapshotNode {
        SnapshotNode(elementType: Int(snapshot.elementType.rawValue), identifier: snapshot.identifier, label: snapshot.label,
                     value: snapshot.value.map { "\($0)" }, placeholder: snapshot.placeholderValue,
                     frame: ScreenRect(x: Double(snapshot.frame.minX), y: Double(snapshot.frame.minY),
                                       w: Double(snapshot.frame.width), h: Double(snapshot.frame.height)),
                     enabled: snapshot.isEnabled, selected: snapshot.isSelected, children: snapshot.children.map(node))
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
