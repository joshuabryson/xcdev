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
            let scene = try readScene()
            lastScene = scene
            return scene.root
        } catch let error as MacAXError {
            throw Self.failure(for: error, during: "reading the tree")
        }
    }

    /// The read skips what goes away under the walk; what it cannot skip (the application's own windows changing) is
    /// read once more, 100 ms later.
    func readScene() throws -> MacScene {
        do {
            return try MacSnapshot(api: api).read(app: app)
        } catch MacAXError.elementGone {
            pause(0.1)
            return try MacSnapshot(api: api).read(app: app)
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
}
