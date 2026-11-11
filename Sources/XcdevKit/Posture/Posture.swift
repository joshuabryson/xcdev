import Foundation

/// A foldable's hinge as `xcd sim fold` names it. Each posture is the angle it sends.
public enum Posture: String, Codable, Sendable, CaseIterable {
    case closed, half, open

    /// The hinge angle in degrees the posture stands for: 0, 90, 180.
    public var degrees: Double {
        switch self {
        case .closed: 0
        case .half: 90
        case .open: 180
        }
    }

    /// How far SpringBoard's angle may be from the one asked for and still be it: iOS 27.2 leaves the hinge 2.6° past
    /// an angle between closed and open (90° from open logs 87.4°, from closed 92.6°), where iOS 27.1 logged 90.0°.
    public static let angleTolerance = 3.0

    /// The posture nearest an angle: closed below 45°, open from 135°, half between.
    public static func nearest(_ degrees: Double) -> Posture {
        if degrees < 45 { return .closed }
        return degrees < 135 ? .half : .open
    }

    /// SpringBoard's word for the posture in its `DCMPose` lines.
    public var springBoardState: String {
        switch self {
        case .closed: "fullyClosed"
        case .half: "partiallyOpen"
        case .open: "openFlat"
        }
    }

    /// The posture a `DCMPose` state word names, with any `+transition` suffix dropped.
    public init?(springBoardState word: String) {
        let base = word.split(separator: "+").first.map(String.init) ?? word
        guard let match = Posture.allCases.first(where: { $0.springBoardState == base }) else { return nil }
        self = match
    }
}

/// What a route is asked to do: set the hinge to an angle, or turn the device.
public enum PostureRequest: Sendable, Equatable {
    case hinge(degrees: Double)
    case orientation(DeviceOrientation)
}

/// The ways of delivering a request.
public enum PostureRouteID: String, Codable, Sendable, CaseIterable {
    case direct
}

/// `xcd sim fold`'s arguments, checked.
public struct FoldOptions: Sendable, Equatable {
    public var posture: Posture?
    public var degrees: Double?
    public var route: PostureRouteID?
    public var device: String?

    public init(posture: Posture? = nil, degrees: Double? = nil, route: PostureRouteID? = nil, device: String? = nil) {
        self.posture = posture
        self.degrees = degrees
        self.route = route
        self.device = device
    }

    /// Nil when the command only reports.
    public var request: PostureRequest? {
        if let degrees { return .hinge(degrees: degrees) }
        return posture.map { .hinge(degrees: $0.degrees) }
    }

    /// Parses the command line's words; every bad value is a `usage` error.
    public static func parse(posture word: String?, angle: Double?, route: String?, device: String?) throws -> FoldOptions {
        var options = FoldOptions(device: device)
        if let word {
            guard let posture = Posture(rawValue: word) else {
                throw XcdError(.usage, "'\(word)' is not a posture", next: "use one of: closed, half, open, or --angle <degrees>")
            }
            options.posture = posture
        }
        if let angle {
            guard word == nil else { throw XcdError(.usage, "a posture and --angle can't be combined", next: "pass one of them") }
            guard (0...180).contains(angle) else {
                throw XcdError(.usage, "--angle \(angle) is outside 0 to 180", next: "0 is closed, 90 half open, 180 open flat")
            }
            options.degrees = angle
        }
        if let route {
            guard let id = PostureRouteID(rawValue: route) else {
                throw XcdError(.usage, "'\(route)' is not a route",
                               next: "use one of: " + PostureRouteID.allCases.map(\.rawValue).joined(separator: ", "))
            }
            options.route = id
        }
        return options
    }
}

/// What the simulator reports about a foldable: which display is active, the hinge when a hinge line
/// (`DCMPose:` or `COMPLETED:`) of this boot said, and the orientation in the pose's own words.
public struct PostureState: Sendable, Equatable {
    public var innerActive: Bool
    public var degrees: Double?
    public var posture: Posture?
    public var orientation: DeviceOrientation?

    public init(innerActive: Bool, degrees: Double? = nil, posture: Posture? = nil, orientation: DeviceOrientation? = nil) {
        self.innerActive = innerActive
        self.degrees = degrees
        self.posture = posture
        self.orientation = orientation
    }

    /// `closed`, `half`, `open`: the line's posture, else the posture nearest its angle (61.7° `closed` is `half`); the
    /// display's `closed` or `open or half` only when nothing else is known.
    public var postureText: String {
        if let posture { return posture.rawValue }
        if let degrees { return Posture.nearest(degrees).rawValue }
        return innerActive ? "open or half" : "closed"
    }

    /// `cover` or `inner`.
    public var display: String { innerActive ? "inner" : "cover" }

    /// Whether this state already is what `request` asks for, so nothing needs sending. The cover
    /// being active is proof of 0° only when no hinge line of this boot is known, since the Duo keeps the cover at
    /// 61.7°; a known angle is decided by `Posture.angleTolerance`.
    public func satisfies(_ request: PostureRequest) -> Bool {
        switch request {
        case .orientation(let wanted):
            return orientation == wanted
        case .hinge(let wanted):
            guard let degrees else { return !innerActive && wanted == 0 }
            return abs(degrees - wanted) <= Posture.angleTolerance
        }
    }
}
