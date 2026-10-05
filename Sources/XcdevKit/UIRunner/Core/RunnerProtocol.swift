import Foundation

public enum RunnerProtocol {
    /// Bumped when a request or result changes shape; xcd restarts a runner that reports another version.
    public static let version = 2
    public static let healthPath = "/health"
    public static let treePath = "/tree"
    public static let tapPath = "/tap"
    public static let waitPath = "/wait"
    public static let longPressPath = "/longpress"
    public static let swipePath = "/swipe"
    public static let typePath = "/type"
    public static let buttonPath = "/button"
    public static let rotatePath = "/rotate"
    public static let pasteboardPath = "/pasteboard"
}

public struct HealthInfo: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    /// The runner app's bundle id.
    public var runner: String
    /// Whether `ElementRole`'s numbers match this Xcode's `XCUIElement.ElementType`.
    public var rolesVerified: Bool

    public init(protocolVersion: Int, runner: String, rolesVerified: Bool) {
        self.protocolVersion = protocolVersion
        self.runner = runner
        self.rolesVerified = rolesVerified
    }
}

public struct TreeRequest: Codable, Sendable, Equatable {
    /// The app to read; nil with `system`.
    public var bundleId: String?
    /// Read Springboard instead of an app.
    public var system: Bool
    public var all: Bool

    public init(bundleId: String?, system: Bool, all: Bool) {
        self.bundleId = bundleId
        self.system = system
        self.all = all
    }
}

/// A tap, a long-press, or a wait.
public struct TargetRequest: Codable, Sendable, Equatable {
    public var bundleId: String?
    public var system: Bool
    public var target: TargetSpec
    public var role: String?
    public var index: Int?
    /// Seconds to keep looking.
    public var timeout: Double
    /// For a wait: wait for the element to be gone.
    public var gone: Bool
    /// For a long-press: seconds to hold. Nil is one second.
    public var duration: Double?
    /// For a tap or a long-press: include the tree as it is afterwards. Nil is false.
    public var tree: Bool?

    public init(bundleId: String?, system: Bool, target: TargetSpec, role: String?, index: Int?, timeout: Double, gone: Bool) {
        self.bundleId = bundleId
        self.system = system
        self.target = target
        self.role = role
        self.index = index
        self.timeout = timeout
        self.gone = gone
    }
}

public struct TreeResult: Codable, Sendable, Equatable {
    public var bundleId: String?
    /// "foreground", "background", "not_running", or "system" (Springboard was asked for).
    public var state: String
    public var screen: ScreenRect
    public var scale: Double
    public var orientation: String
    public var keyboard: Bool
    public var elements: [TreeElement]
}

public struct ActionResult: Codable, Sendable, Equatable {
    /// The element acted on or waited for; nil for a point target or a `gone` wait.
    public var element: TreeElement?
    public var x: Double?
    public var y: Double?
    public var ms: Int
    /// Where a swipe ended.
    public var toX: Double?
    public var toY: Double?
    /// How text was entered: "keyboard" or "paste".
    public var method: String?
    /// The tree after the action, when the request asked for it and it could be read.
    public var tree: TreeResult?
}

public struct RunnerFailure: Codable, Sendable, Equatable, Error {
    public enum Code {
        public static let notFound = "element_not_found"
        public static let notHittable = "element_not_hittable"
        public static let ambiguous = "element_ambiguous"
        public static let staleRef = "stale_ref"
        public static let waitTimeout = "wait_timeout"
        public static let appNotForeground = "app_not_foreground"
        public static let appCrashed = "app_crashed"
        /// The device can't do what was asked: it has no such hardware button.
        public static let unsupported = "unsupported"
        /// There is no keyboard on screen and no element has keyboard focus, so text has nowhere to go.
        public static let nothingFocused = "nothing_focused"
        public static let badRequest = "bad_request"
        public static let `internal` = "internal"
    }

    public var code: String
    public var message: String
    /// For an ambiguous target: the matches, with refs.
    public var candidates: [TreeElement]
    /// Labels and identifiers on screen, for "did you mean".
    public var seen: [String]
    public var frame: ScreenRect?
    /// XCTest issues recorded while handling the request.
    public var issues: [String]

    public init(code: String, message: String, candidates: [TreeElement] = [], seen: [String] = [], frame: ScreenRect? = nil,
                issues: [String] = []) {
        self.code = code
        self.message = message
        self.candidates = candidates
        self.seen = seen
        self.frame = frame
        self.issues = issues
    }
}

public struct RunnerReply<Payload: Codable>: Codable {
    public var ok: Bool
    public var result: Payload?
    public var failure: RunnerFailure?

    public init(_ outcome: Result<Payload, RunnerFailure>) {
        switch outcome {
        case .success(let result):
            ok = true
            self.result = result
            failure = nil
        case .failure(let failure):
            ok = false
            result = nil
            self.failure = failure
        }
    }
}
