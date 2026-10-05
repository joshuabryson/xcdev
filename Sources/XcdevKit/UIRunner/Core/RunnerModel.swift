import Foundation

// RunnerCore: these files are compiled into xcd AND into the UI runner (Swift 5, iOS 17). Foundation only.

/// A rectangle in screen points, in the current interface orientation.
public struct ScreenRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var midX: Double { x + w / 2 }
    public var midY: Double { y + h / 2 }
    public var isEmpty: Bool { w <= 0 || h <= 0 }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + w && py >= y && py < y + h
    }

    /// "24,700 354x50": whole numbers without a decimal, others with one.
    public var text: String { "\(Self.number(x)),\(Self.number(y)) \(Self.number(w))x\(Self.number(h))" }

    static func number(_ value: Double) -> String {
        guard value.isFinite && value.magnitude < 1e15 else { return "?" }
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// One element of an XCUITest snapshot, as the runner reads it.
public struct SnapshotNode: Codable, Sendable, Equatable {
    public var elementType: Int
    public var identifier: String
    public var label: String
    public var value: String?
    public var placeholder: String?
    public var frame: ScreenRect
    public var enabled: Bool
    public var selected: Bool
    /// Whether it has keyboard focus; nil when the device can't say.
    public var focused: Bool?
    public var children: [SnapshotNode]

    public init(elementType: Int, identifier: String, label: String, value: String?, placeholder: String?, frame: ScreenRect,
                enabled: Bool, selected: Bool, children: [SnapshotNode], focused: Bool? = nil) {
        self.focused = focused
        self.elementType = elementType
        self.identifier = identifier
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.frame = frame
        self.enabled = enabled
        self.selected = selected
        self.children = children
    }
}

/// Where an element comes from: the target app, or Springboard (system alerts, the Home Screen).
public enum ElementSource: String, Codable, Sendable {
    case app, system
}

/// One row of `xcd ui tree`.
public struct TreeElement: Codable, Sendable, Equatable {
    /// "e3"; nil for an element that wasn't given a ref.
    public var ref: String?
    public var role: String
    public var label: String
    public var identifier: String
    public var value: String?
    public var placeholder: String?
    public var frame: ScreenRect
    public var depth: Int
    public var enabled: Bool
    public var selected: Bool
    public var source: ElementSource
    public var offscreen: Bool
    public var window: Int
}
