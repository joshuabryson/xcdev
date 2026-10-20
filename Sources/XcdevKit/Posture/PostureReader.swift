import Foundation

/// Reads a foldable's state from the host: devicectl for the displays and the orientation,
/// the simulator's own log for the hinge. Both are public tools; nothing here is private API.
public struct PostureReader: Sendable {
    public let runner: any ProcessRunning
    public let developerDir: String?
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void

    public init(runner: any ProcessRunning, developerDir: String?, now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.runner = runner
        self.developerDir = developerDir
        self.now = now
        self.sleep = sleep
    }

    /// SpringBoard's `DCMPose` lines, which are debug level.
    public static let predicate = "process == \"SpringBoard\" AND category == \"DevicePose\" AND eventMessage BEGINSWITH \"DCMPose\""

    /// `xcrun devicectl device info displays`, with its JSON on stdout; about 0.2 s.
    public func displays(udid: String) async throws -> DisplaysRead {
        let args = ["devicectl", "device", "info", "displays", "--device", udid, "--json-output", "-"]
        let out = try await runner.runChecked(.xcrun(args, developerDir: developerDir, timeout: .seconds(30)),
                                              code: .simulatorFailed, next: "run `xcd doctor`")
        return try DisplaysRead.parse(out.stdout)
    }

    /// The `DCMPose` lines of the simulator's log for `window`: `boot` for this boot, or `15s`.
    public func poseLines(udid: String, last window: String) async throws -> [PoseLine] {
        let args = ["simctl", "spawn", udid, "log", "show", "--last", window, "--debug", "--style", "compact",
                    "--predicate", Self.predicate]
        let out = try await runner.runChecked(.xcrun(args, developerDir: developerDir, timeout: .seconds(60)),
                                              code: .simulatorFailed, next: "run `xcd doctor`")
        return PoseLine.parseAll(out.stdoutString)
    }

    /// The state now: the displays, refined by the last `DCMPose` line of this boot.
    public func state(udid: String) async throws -> PostureState {
        let displays = try await displays(udid: udid)
        let last = try await poseLines(udid: udid, last: "boot").last
        return PostureState(innerActive: displays.innerActive, degrees: last?.degrees, posture: last?.posture,
                            orientation: displays.poseOrientation)
    }
}
