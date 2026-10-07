import XcdevKit

/// The Mac app that shows simulators in windows: Simulator.app, or Device Hub, which takes its place in Xcode 27
/// (that Xcode installs no Simulator.app). The real-simulator tests check that driving a simulator never starts it
/// and never leaves it in front.
public enum SimulatorApp {
    /// What its process is called.
    static let processNames = ["Simulator", "DeviceHub"]
    /// What `lsappinfo` calls it.
    static let appNames = ["Simulator", "Device Hub"]

    public static func isRunning(_ runner: any ProcessRunning) async throws -> Bool {
        for name in processNames {
            if try await runner.run(Invocation("/usr/bin/pgrep", ["-x", name])).succeeded { return true }
        }
        return false
    }

    /// Whether `app`, an app as `lsappinfo` names it, is this one.
    public static func isNamed(_ app: String) -> Bool {
        appNames.contains { app.contains($0) }
    }
}
