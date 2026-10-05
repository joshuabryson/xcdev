import Foundation

/// A point on the screen, in points.
public struct ScreenPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// What every action carries besides its own arguments: where to act, how long to look, and whether to send the tree back.
public struct ActionScope: Codable, Sendable, Equatable {
    /// The app to act on; nil with `system`.
    public var bundleId: String?
    /// Act on Springboard instead of an app.
    public var system: Bool
    /// Seconds to keep looking for the element.
    public var timeout: Double
    /// Include the tree as it is after the action.
    public var tree: Bool

    public init(bundleId: String?, system: Bool, timeout: Double, tree: Bool) {
        self.bundleId = bundleId
        self.system = system
        self.timeout = timeout
        self.tree = tree
    }
}

/// Which element an action wants.
public struct ElementQuery: Codable, Sendable, Equatable {
    public var target: TargetSpec
    public var role: String?
    public var index: Int?

    public init(target: TargetSpec, role: String?, index: Int?) {
        self.target = target
        self.role = role
        self.index = index
    }
}

extension TargetRequest {
    var scope: ActionScope { ActionScope(bundleId: bundleId, system: system, timeout: timeout, tree: tree ?? false) }
    var query: ElementQuery { ElementQuery(target: target, role: role, index: index) }
}

/// The way the finger moves: `up` moves it up the screen, which scrolls a list down.
public enum SwipeDirection: String, Codable, Sendable, CaseIterable {
    case up, down, left, right
}

/// A swipe in a direction (across `on`, or the screen), or from one point to another.
public struct SwipeRequest: Codable, Sendable, Equatable {
    public var scope: ActionScope
    public var direction: SwipeDirection?
    public var on: ElementQuery?
    public var from: ScreenPoint?
    public var to: ScreenPoint?

    public init(scope: ActionScope, direction: SwipeDirection?, on: ElementQuery?, from: ScreenPoint?, to: ScreenPoint?) {
        self.scope = scope
        self.direction = direction
        self.on = on
        self.from = from
        self.to = to
    }
}

public struct TypeRequest: Codable, Sendable, Equatable {
    public var scope: ActionScope
    public var text: String
    /// The field to tap first; nil types into whatever has focus.
    public var into: ElementQuery?
    /// Select everything in the field and delete it first.
    public var clear: Bool
    /// Press Return afterwards.
    public var submit: Bool

    public init(scope: ActionScope, text: String, into: ElementQuery?, clear: Bool, submit: Bool) {
        self.scope = scope
        self.text = text
        self.into = into
        self.clear = clear
        self.submit = submit
    }
}

/// The hardware buttons XCUITest can press in a simulator.
public enum HardwareButton: String, Codable, Sendable, CaseIterable {
    case home, action, camera
}

public enum DeviceOrientation: String, Codable, Sendable, CaseIterable {
    case portrait
    case portraitUpsideDown = "portrait-upside-down"
    case landscapeLeft = "landscape-left"
    case landscapeRight = "landscape-right"
}

/// A button press or a rotation: `name` is a `HardwareButton` or a `DeviceOrientation`.
public struct DeviceRequest: Codable, Sendable, Equatable {
    public var scope: ActionScope
    public var name: String

    public init(scope: ActionScope, name: String) {
        self.scope = scope
        self.name = name
    }
}

public struct PasteboardRequest: Codable, Sendable, Equatable {
    /// A PNG or JPEG file's bytes.
    public var image: Data

    public init(image: Data) {
        self.image = image
    }
}

public struct PasteboardResult: Codable, Sendable, Equatable {
    /// Whether the device's pasteboard holds an image after the request.
    public var hasImages: Bool
}
