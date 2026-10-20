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

/// One `DCMPose` line of SpringBoard's DevicePose log, such as
/// `2026-10-17 19:59:48.502 Df SpringBoard[88269:1063c187] [com.apple.SpringBoard:DevicePose] DCMPose: 180.0° (1.00 fold:1.00): openFlat [device:Pu]`.
public struct PoseLine: Sendable, Equatable {
    public var timestamp: Date
    public var degrees: Double
    public var posture: Posture?
    /// The state word as logged, suffix included: `partiallyOpen+toClosed`.
    public var state: String

    /// Nil for any other line.
    public static func parse(_ line: String) -> PoseLine? {
        let pattern = /^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) .*DCMPose: ([0-9.]+)° \([^)]*\): ([A-Za-z+]+)/
        guard let match = line.firstMatch(of: pattern), let degrees = Double(match.2),
              let timestamp = timestamp(String(match.1)) else { return nil }
        let state = String(match.3)
        return PoseLine(timestamp: timestamp, degrees: degrees, posture: Posture(springBoardState: state), state: state)
    }

    /// Every `DCMPose` line of a `log show --style compact` output, oldest first.
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
