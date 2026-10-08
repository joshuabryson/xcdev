import Foundation

/// The Mac app that shows a simulator's screen to a person. Xcode 27 replaced Simulator.app with Device Hub, which
/// sits beside the Developer folder in the Xcode bundle.
public enum SimulatorViewer: Sendable, Equatable {
    case simulatorApp
    /// With the path of the DeviceHub.app to use.
    case deviceHub(String)

    static let firstXcodeWithDeviceHub = Version(components: [27])

    /// The app of the Xcode in use.
    public init(xcode: XcodeInstall) {
        let hasDeviceHub = (Version(xcode.version) ?? .zero) >= Self.firstXcodeWithDeviceHub
        self = hasDeviceHub ? .deviceHub(xcode.path + "/Contents/Applications/DeviceHub.app") : .simulatorApp
    }

    /// What a person should know once the app is open. Device Hub, when it quits, shuts down the simulators that
    /// are booted, whoever booted them.
    public var notes: [String] {
        switch self {
        case .simulatorApp: []
        case .deviceHub: ["quitting Device Hub shuts down every booted simulator on this Mac, other worktrees' clones included"]
        }
    }
}

extension SimctlClient {
    /// Brings the device up in `viewer` for a person to watch, starting the app if it isn't running.
    public func show(udid: String, in viewer: SimulatorViewer) async throws {
        switch viewer {
        case .simulatorApp:
            try await openSimulatorApp(udid: udid)
        case .deviceHub(let app):
            // Device Hub has one window for every device and selects the one a `devices:` URL names. It is named by
            // path, so that with two Xcodes installed the URL goes to the one in use.
            try await runner.runChecked(Invocation("/usr/bin/open", ["-a", app, "devices://manage/select?id=\(udid)"]))
        }
    }
}
