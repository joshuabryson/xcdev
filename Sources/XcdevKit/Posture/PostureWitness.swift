import Foundation

/// What `xcrun devicectl device info displays` says about a foldable.
public struct DisplaysRead: Sendable, Equatable {
    /// The inner display is active: the device is open or half open. The cover (`primary`) active means closed.
    public var innerActive: Bool
    /// devicectl's word: portrait, landscapeLeft, landscapeRight, portraitUpsideDown; "" when it reports none.
    public var deviceOrientation: String

    public init(innerActive: Bool, deviceOrientation: String) {
        self.innerActive = innerActive
        self.deviceOrientation = deviceOrientation
    }

    public static func parse(_ json: Data) throws -> DisplaysRead {
        struct Display: Decodable { let active: Bool; let primary: Bool }
        struct Orientation: Decodable { let currentDeviceOrientation: String }
        struct Result: Decodable { let displays: [Display]; let orientation: Orientation? }
        struct Envelope: Decodable { let result: Result }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: json)
        } catch {
            throw XcdError(.simulatorFailed, "could not read `devicectl device info displays`", next: "run `xcd doctor`",
                           details: ["\(error)"])
        }
        return DisplaysRead(innerActive: envelope.result.displays.contains { $0.active && !$0.primary },
                            deviceOrientation: envelope.result.orientation?.currentDeviceOrientation ?? "")
    }

    /// The pose this read means. Closed, devicectl's word is the pose; open, it is the pose turned a quarter.
    /// The open table's `landscapeLeft` row follows from the others and was not observed.
    public var poseOrientation: DeviceOrientation? {
        let table: [String: DeviceOrientation] = innerActive
            ? ["landscapeRight": .portrait, "portrait": .landscapeLeft, "portraitUpsideDown": .landscapeRight,
               "landscapeLeft": .portraitUpsideDown]
            : ["portrait": .portrait, "landscapeLeft": .landscapeLeft, "landscapeRight": .landscapeRight,
               "portraitUpsideDown": .portraitUpsideDown]
        return table[deviceOrientation]
    }
}

/// One hinge line of SpringBoard's log: a `DCMPose` line of its DevicePose log, such as
/// `2026-10-17 19:59:48.502 Df SpringBoard[88269:1063c187] [com.apple.SpringBoard:DevicePose] DCMPose: 180.0° (1.00 fold:1.00): openFlat [device:Pu]`,
/// or a display transition's `COMPLETED:` line, whose angle and state follow a `|`, such as
/// `… [com.apple.SpringBoard:DisplayContentMode] COMPLETED:     .inner:pri .cover:aux | 90.0° (0.50 fold:1.00): partiallyOpen+foldAvoidance [device:Pu]`.
public struct PoseLine: Sendable, Equatable {
    public var timestamp: Date
    public var degrees: Double
    public var posture: Posture?
    /// The state word as logged, suffix included: `partiallyOpen+toClosed`.
    public var state: String
    /// For a `COMPLETED:` line, whether the transition left the inner display primary (`.inner:pri`) rather than the
    /// cover (`.cover:pri`); nil for a `DCMPose` line, which names no display.
    public var innerPrimary: Bool?

    /// Nil for any other line, a transition's `STARTING:` and `DCMResolved:` lines among them.
    public static func parse(_ line: String) -> PoseLine? {
        let pattern = /^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) .*(?:DCMPose: |COMPLETED: ([^|]*)\| )([0-9.]+)° \([^)]*\): ([A-Za-z+]+)/
        guard let match = line.firstMatch(of: pattern), let degrees = Double(match.3),
              let timestamp = timestamp(String(match.1)) else { return nil }
        let state = String(match.4)
        return PoseLine(timestamp: timestamp, degrees: degrees, posture: Posture(springBoardState: state), state: state,
                        innerPrimary: match.2.flatMap(innerPrimary))
    }

    /// From a `COMPLETED:` line's displays, whether the inner one is primary; nil when neither is.
    static func innerPrimary(_ displays: Substring) -> Bool? {
        if displays.contains(".inner:pri") { return true }
        return displays.contains(".cover:pri") ? false : nil
    }

    /// Every hinge line of a `log show --style compact` output, oldest first.
    public static func parseAll(_ output: String) -> [PoseLine] {
        output.split(separator: "\n").compactMap { parse(String($0)) }
    }

    /// The log's local timestamps, `yyyy-MM-dd HH:mm:ss.SSS`.
    public static func timestamp(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.date(from: text)
    }
}

/// One `Updated device orientation update to:` line of SpringBoard's DeviceOrientationUpdateDeferral log, such as
/// `… [com.apple.SpringBoard:DeviceOrientationUpdateDeferral] Updated device orientation update to: landscapeLeft (3) animated: YES …`.
/// SpringBoard writes one for every turn it applies, and none for a turn it drops.
public struct OrientationLine: Sendable, Equatable {
    public var timestamp: Date
    /// SpringBoard's word: portrait, portraitUpsideDown, landscapeLeft, landscapeRight.
    public var word: String

    /// The device orientation the word names. It is the device's own in both postures, unlike devicectl's word, which is
    /// the screen's and is turned a quarter while open. Nil for any other word.
    public var orientation: DeviceOrientation? {
        switch word {
        case "portrait": .portrait
        case "portraitUpsideDown": .portraitUpsideDown
        case "landscapeLeft": .landscapeLeft
        case "landscapeRight": .landscapeRight
        default: nil
        }
    }

    /// Nil for any other line, a `Deferred device orientation update to:` line among them.
    public static func parse(_ line: String) -> OrientationLine? {
        let pattern = /^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) .*Updated device orientation update to: ([A-Za-z]+) \(\d+\)/
        guard let match = line.firstMatch(of: pattern), let timestamp = PoseLine.timestamp(String(match.1)) else { return nil }
        return OrientationLine(timestamp: timestamp, word: String(match.2))
    }

    /// Every orientation update of a `log show --style compact` output, oldest first.
    public static func parseAll(_ output: String) -> [OrientationLine] {
        output.split(separator: "\n").compactMap { parse(String($0)) }
    }
}

/// What one read of the simulator's log says: its hinge lines and its orientation updates, each oldest first.
public struct WitnessLog: Sendable, Equatable {
    public var poses: [PoseLine]
    public var orientations: [OrientationLine]

    public init(poses: [PoseLine] = [], orientations: [OrientationLine] = []) {
        self.poses = poses
        self.orientations = orientations
    }

    public init(parsing output: String) {
        self.init(poses: PoseLine.parseAll(output), orientations: OrientationLine.parseAll(output))
    }
}
