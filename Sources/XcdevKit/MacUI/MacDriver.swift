import Foundation

/// `DeviceDriving` for one running Mac app, over the Accessibility API. Created for one command.
public final class MacDriver: DeviceDriving {
    public let pid: Int32
    let api: any AccessibilityAPI
    let app: AXElement
    /// The last tree read, for the window a screenshot takes and the scale.
    public private(set) var lastScene: MacScene?
    /// The element `focus(node:)` last focused, for `--clear`.
    var focusedElement: AXElement?

    /// The message every failed read carries: what a person at the Mac may have to do.
    public static let notAnswering = "the app did not answer the accessibility request within 2 s; its main thread may be busy, "
        + "or it may be waiting on a system prompt only the person at the Mac can answer"
    /// The message for an element the app no longer has.
    static let gone = "the element is no longer there; the app may have quit or the window closed"

    public init(pid: Int32, api: any AccessibilityAPI) {
        self.pid = pid
        self.api = api
        app = api.application(pid: pid)
    }

    /// The one conversion of an Accessibility error into what the engine reports; `during` names what was being done.
    static func failure(for error: MacAXError, during: String) -> RunnerFailure {
        let message: String
        switch error {
        case .cannotComplete: message = notAnswering
        case .elementGone: message = gone
        }
        return RunnerFailure(code: RunnerFailure.Code.internal, message: message, issues: ["\(during): \(error)"])
    }

    public func appState(_ bundleId: String) -> AppRunState { api.isRunning(pid: pid) ? .foreground : .notRunning }

    public func appSnapshot(_ bundleId: String) throws -> SnapshotNode {
        do {
            let scene = try MacSnapshot(api: api).read(app: app)
            lastScene = scene
            return scene.root
        } catch let error as MacAXError {
            throw Self.failure(for: error, during: "reading the tree")
        }
    }

    public func systemSnapshot() throws -> SnapshotNode {
        throw RunnerFailure(code: RunnerFailure.Code.unsupported,
                            message: "a Mac has no Home Screen to read, and the desktop is the person's; read the app's own windows with `xcd ui tree`")
    }

    /// A Mac shows no system alert over the app: a sheet or an alert window is the app's own and is in its tree.
    public func systemAlert() -> SnapshotNode? { nil }

    public var scale: Double {
        guard let main = lastScene?.mainWindow, let rect = try? api.rect(of: main) else { return 2 }
        return api.screenScale(containing: rect)
    }

    public var orientation: String { "none" }
    public var keyboardAppears: Bool { false }

    public func pause(_ seconds: Double) { usleep(UInt32(max(0, seconds) * 1_000_000)) }
    public func now() -> Double { Date().timeIntervalSinceReferenceDate }

    /// The element a node names, from the handle the snapshot gave it.
    func element(of node: FlatNode) throws -> AXElement {
        guard let handle = node.handle, let token = Int(handle) else {
            throw RunnerFailure(code: RunnerFailure.Code.internal, message: "the element has no handle; read the tree again")
        }
        return AXElement(token: token)
    }

    // Temporary until the actions arrive in `MacDriver+Actions.swift`.

    static func notYet(_ action: String) -> RunnerFailure {
        RunnerFailure(code: RunnerFailure.Code.unsupported, message: "\(action) on a Mac is not built yet")
    }

    public func tap(x: Double, y: Double) throws { throw Self.notYet("a tap") }
    public func press(x: Double, y: Double, duration: Double) throws { throw Self.notYet("a long-press") }
    public func drag(from: ScreenPoint, to: ScreenPoint, duration: Double) throws { throw Self.notYet("a drag") }
    public func typeText(_ text: String) throws { throw Self.notYet("typing") }
    public func pressKey(_ key: String, command: Bool) throws { throw Self.notYet("a key press") }
    public func pressButton(_ button: HardwareButton) throws -> Bool { throw Self.notYet("a button press") }
    public func rotate(to orientation: DeviceOrientation) throws { throw Self.notYet("a rotation") }
    public func setPasteboard(text: String) { /* the Mac's pasteboard is the person's; nothing is written */ }
    public func setPasteboard(image: Data) -> Bool { false }
}
