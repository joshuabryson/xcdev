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

    /// SpringBoard's `DCMPose` lines, and the `COMPLETED:` lines of its display transitions, which alone
    /// carry the angle of a hinge change merged into a running transition.
    public static let predicate = "process == \"SpringBoard\" AND ((category == \"DevicePose\" AND eventMessage BEGINSWITH \"DCMPose\") "
        + "OR (category == \"DisplayContentMode\" AND eventMessage BEGINSWITH \"COMPLETED\"))"

    /// `xcrun devicectl device info displays`, with its JSON on stdout; about 0.2 s.
    public func displays(udid: String) async throws -> DisplaysRead {
        let args = ["devicectl", "device", "info", "displays", "--device", udid, "--json-output", "-"]
        let out = try await runner.runChecked(.xcrun(args, developerDir: developerDir, timeout: .seconds(30)),
                                              code: .simulatorFailed, next: "run `xcd doctor`")
        return try DisplaysRead.parse(out.stdout)
    }

    /// The hinge lines (`DCMPose:` and `COMPLETED:`) of the simulator's log for `window`: `boot` for this boot, or
    /// `15s`.
    public func poseLines(udid: String, last window: String) async throws -> [PoseLine] {
        let args = ["simctl", "spawn", udid, "log", "show", "--last", window, "--debug", "--style", "compact",
                    "--predicate", Self.predicate]
        let out = try await runner.runChecked(.xcrun(args, developerDir: developerDir, timeout: .seconds(60)),
                                              code: .simulatorFailed, next: "run `xcd doctor`")
        return PoseLine.parseAll(out.stdoutString)
    }

    /// The state now: the displays, refined by the last hinge line of this boot.
    public func state(udid: String) async throws -> PostureState {
        let displays = try await displays(udid: udid)
        let last = try await poseLines(udid: udid, last: "boot").last
        return PostureState(innerActive: displays.innerActive, degrees: last?.degrees, posture: last?.posture,
                            orientation: displays.poseOrientation)
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

    /// Polls devicectl every 250 ms, and the log once the display agrees, until the request is witnessed or 5 s pass
    ///. Throws `posture_failed` when the display never agreed; `verified: false` when only it did, with the
    /// newest line after the send, if any, so an angle the simulator rounds is reported as it shows it.
    public func waitForWitness(_ request: PostureRequest, udid: String, since: Date) async throws -> PostureVerdict {
        let deadline = now().addingTimeInterval(DurationText.seconds(Self.witnessTimeout))
        var displays = try await self.displays(udid: udid)
        var line: PoseLine?
        while true {
            if Self.displaysAgree(request, displays) {
                if Self.displaysSuffice(request) { return PostureVerdict(state: Self.state(displays, nil), verified: true) }
                line = try await poseLines(udid: udid, last: "15s").last { $0.timestamp >= since }
                if let line, Self.lineConfirms(request, line) { return PostureVerdict(state: Self.state(displays, line), verified: true) }
            }
            guard now() < deadline else { break }
            try await sleep(.milliseconds(250))
            displays = try await self.displays(udid: udid)
        }
        guard Self.displaysAgree(request, displays) else { throw Self.noWitness(request, displays) }
        return PostureVerdict(state: Self.state(displays, line), verified: false)
    }

    /// The display side of a request: the mapped word for a turn; for the hinge, the cover at 0°, the inner display from
    /// 90°, and either display between, since the Duo swaps displays at 85° and keeps the cover at 61.7°.
    static func displaysAgree(_ request: PostureRequest, _ displays: DisplaysRead) -> Bool {
        switch request {
        case .orientation(let wanted):
            return displays.poseOrientation == wanted
        case .hinge(let degrees):
            if degrees == 0 { return !displays.innerActive }
            return degrees < 90 || displays.innerActive
        }
    }

    /// 0° and every orientation are verified by devicectl alone; every other angle, half and open among
    /// them, needs its hinge line.
    static func displaysSuffice(_ request: PostureRequest) -> Bool {
        switch request {
        case .orientation: return true
        case .hinge(let degrees): return degrees == 0
        }
    }

    /// A hinge line within 1° of the angle asked for.
    static func lineConfirms(_ request: PostureRequest, _ line: PoseLine) -> Bool {
        guard case .hinge(let degrees) = request else { return false }
        return abs(line.degrees - degrees) <= 1
    }

    static func state(_ displays: DisplaysRead, _ line: PoseLine?) -> PostureState {
        PostureState(innerActive: displays.innerActive, degrees: line?.degrees, posture: line?.posture,
                     orientation: displays.poseOrientation)
    }

    /// A turn's `next:` names the tested recovery, since SpringBoard drops about one cover rotation in fifty and a
    /// re-sent turn is a no-op.
    static func noWitness(_ request: PostureRequest, _ displays: DisplaysRead) -> XcdError {
        let next = switch request {
        case .hinge: "run `xcd sim fold` to see the posture it is in, then `xcd doctor`"
        case .orientation:
            "run `xcd sim fold` to see the posture it is in, then rotate to another orientation and back: the simulator sometimes drops a turn"
        }
        return XcdError(.postureFailed, "the simulator did not show \(describe(request)) within \(DurationText.format(witnessTimeout))",
                        next: next,
                        details: ["seen: display \(displays.innerActive ? "inner" : "cover"), orientation \(displays.deviceOrientation)"])
    }

    static func describe(_ request: PostureRequest) -> String {
        switch request {
        case .hinge(let degrees): return "the hinge at \(Int(degrees.rounded()))°"
        case .orientation(let orientation): return "the \(orientation.rawValue) orientation"
        }
    }
}
