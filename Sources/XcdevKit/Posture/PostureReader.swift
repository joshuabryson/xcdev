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

    /// SpringBoard's `DCMPose` lines; the `COMPLETED:` lines of its display transitions, which alone carry
    /// the angle of a hinge change merged into a running transition; and its orientation updates,
    /// which name the device orientation of every turn it applies.
    public static let predicate = "process == \"SpringBoard\" AND ((category == \"DevicePose\" AND eventMessage BEGINSWITH \"DCMPose\") "
        + "OR (category == \"DisplayContentMode\" AND eventMessage BEGINSWITH \"COMPLETED\") "
        + "OR (category == \"DeviceOrientationUpdateDeferral\" AND eventMessage BEGINSWITH \"Updated device orientation update\"))"

    /// `xcrun devicectl device info displays`, with its JSON on stdout; about 0.2 s.
    public func displays(udid: String) async throws -> DisplaysRead {
        let args = ["devicectl", "device", "info", "displays", "--device", udid, "--json-output", "-"]
        let out = try await runner.runChecked(.xcrun(args, developerDir: developerDir, timeout: .seconds(30)),
                                              code: .simulatorFailed, next: "run `xcd doctor`")
        return try DisplaysRead.parse(out.stdout)
    }

    /// The hinge lines and the orientation updates of the simulator's log for `window`, in one read: `boot` for this
    /// boot, or `15s`.
    public func witnessLog(udid: String, last window: String) async throws -> WitnessLog {
        let args = ["simctl", "spawn", udid, "log", "show", "--last", window, "--debug", "--style", "compact",
                    "--predicate", Self.predicate]
        let out = try await runner.runChecked(.xcrun(args, developerDir: developerDir, timeout: .seconds(60)),
                                              code: .simulatorFailed, next: "run `xcd doctor`")
        return WitnessLog(parsing: out.stdoutString)
    }

    /// The state now: the displays, refined by the last hinge line and the last orientation update of this boot; the
    /// orientation is devicectl's mapped word only when the boot has no update.
    public func state(udid: String) async throws -> PostureState {
        let displays = try await displays(udid: udid)
        let log = try await witnessLog(udid: udid, last: "boot")
        let orientation = log.orientations.isEmpty ? displays.poseOrientation : log.orientations.last?.orientation
        return PostureState(innerActive: displays.innerActive, degrees: log.poses.last?.degrees, posture: log.poses.last?.posture,
                            orientation: orientation)
    }
}

/// A request and the state read before it is sent, which the witness needs: the cover alone proves 0° only when the
/// inner display was active before, and what the request leaves alone keeps the state it had.
public struct PostureChange: Sendable, Equatable {
    public var request: PostureRequest
    public var before: PostureState

    public init(_ request: PostureRequest, from before: PostureState) {
        self.request = request
        self.before = before
    }
}

/// The outcome of waiting for the simulator to show a request's effect.
public struct PostureVerdict: Sendable, Equatable {
    public var state: PostureState
    /// True when a witness named the requested state or angle; false when only the display agreed.
    public var verified: Bool

    public init(state: PostureState, verified: Bool) {
        self.state = state
        self.verified = verified
    }
}

extension PostureReader {
    public static let witnessTimeout = Duration.seconds(5)

    /// Polls devicectl every 250 ms, and the log once the display agrees (for a turn, every poll), until the request is
    /// witnessed or 5 s pass. Throws `posture_failed` when the display never agreed or a turn was never
    /// witnessed; `verified: false` when only the display agreed with a hinge request, with the newest line after the
    /// send, if any, so an angle the simulator rounds is reported as it shows it.
    public func waitForWitness(_ change: PostureChange, udid: String, since: Date) async throws -> PostureVerdict {
        let deadline = now().addingTimeInterval(DurationText.seconds(Self.witnessTimeout))
        var displays = try await self.displays(udid: udid)
        var log = WitnessLog()
        while true {
            if Self.displaysAgree(change.request, displays) {
                if Self.displaysSuffice(change) { return PostureVerdict(state: Self.state(displays, log, since: since, for: change), verified: true) }
                log = try await witnessLog(udid: udid, last: "15s")
                if Self.logConfirms(change.request, log, since: since) {
                    return PostureVerdict(state: Self.state(displays, log, since: since, for: change), verified: true)
                }
            }
            guard now() < deadline else { break }
            try await sleep(.milliseconds(250))
            displays = try await self.displays(udid: udid)
        }
        guard case .hinge = change.request, Self.displaysAgree(change.request, displays) else { throw Self.noWitness(change.request, displays) }
        return PostureVerdict(state: Self.state(displays, log, since: since, for: change), verified: false)
    }

    /// The display side of a request. For the hinge, the cover at 0°, the inner display from 90°, and either display
    /// between, since the Duo swaps displays at 85° and keeps the cover at 61.7°. For a turn, always:
    /// devicectl's word is the screen's, which a closed Home Screen never turns.
    static func displaysAgree(_ request: PostureRequest, _ displays: DisplaysRead) -> Bool {
        switch request {
        case .orientation:
            return true
        case .hinge(let degrees):
            if degrees == 0 { return !displays.innerActive }
            return degrees < 90 || displays.innerActive
        }
    }

    /// Only 0° is verified by devicectl alone, and only when the inner display was active before the send:
    /// the Duo keeps the cover on up to 85°, so a cover that was already on proves nothing, and a hinge line within 1°
    /// of 0° must follow. Every other angle needs its hinge line, and a turn its orientation update.
    static func displaysSuffice(_ change: PostureChange) -> Bool {
        guard case .hinge(let degrees) = change.request else { return false }
        return degrees == 0 && change.before.innerActive
    }

    /// For the hinge, the newest hinge line after the send is within 1° of the angle asked for; for a turn, the newest
    /// orientation update after the send names the orientation asked for.
    static func logConfirms(_ request: PostureRequest, _ log: WitnessLog, since: Date) -> Bool {
        switch request {
        case .hinge(let degrees):
            guard let line = log.poses.last(where: { $0.timestamp >= since }) else { return false }
            return abs(line.degrees - degrees) <= 1
        case .orientation(let wanted):
            return log.orientations.last { $0.timestamp >= since }?.orientation == wanted
        }
    }

    /// A verdict's state: the displays now; the hinge from the newest hinge line after the send, else unknown for a
    /// hinge request and, for a turn, which moves no hinge, as read before the send; the orientation from the newest
    /// update after the send, else as read before the send, since a hinge request turns nothing.
    static func state(_ displays: DisplaysRead, _ log: WitnessLog, since: Date, for change: PostureChange) -> PostureState {
        let update = log.orientations.last { $0.timestamp >= since }
        var state = PostureState(innerActive: displays.innerActive, orientation: update?.orientation ?? change.before.orientation)
        if let line = log.poses.last(where: { $0.timestamp >= since }) {
            state.degrees = line.degrees
            state.posture = line.posture
        } else if case .orientation = change.request {
            state.degrees = change.before.degrees
            state.posture = change.before.posture
        }
        return state
    }

    /// A turn's `next:` names the tested recovery, since SpringBoard drops about one cover rotation in fifty and a
    /// re-sent turn is a no-op; its details say no orientation update came, and what the screen says.
    static func noWitness(_ request: PostureRequest, _ displays: DisplaysRead) -> XcdError {
        let message = "the simulator did not show \(describe(request)) within \(DurationText.format(witnessTimeout))"
        switch request {
        case .hinge:
            return XcdError(.postureFailed, message, next: "run `xcd sim fold` to see the posture it is in, then `xcd doctor`",
                            details: ["seen: display \(displays.innerActive ? "inner" : "cover"), orientation \(displays.deviceOrientation)"])
        case .orientation:
            return XcdError(.postureFailed, message,
                            next: "run `xcd sim fold` to see the posture it is in, wait a few seconds, then rotate to another orientation and back: the simulator sometimes drops a turn",
                            details: ["seen: no orientation update; screen \(displays.deviceOrientation)"])
        }
    }

    static func describe(_ request: PostureRequest) -> String {
        switch request {
        case .hinge(let degrees): return "the hinge at \(Int(degrees.rounded()))°"
        case .orientation(let orientation): return "the \(orientation.rawValue) orientation"
        }
    }
}
