import AppKit
import ApplicationServices

/// One element of another app's Accessibility tree, as a token into the API's table for this command.
public struct AXElement: Hashable, Sendable {
    public let token: Int
    public init(token: Int) { self.token = token }
}

/// A key event: a virtual key code, and the text it carries when it is a character key.
public struct MacKey: Sendable, Equatable {
    public let code: UInt16
    public let text: String?
    public init(code: UInt16, text: String?) {
        self.code = code
        self.text = text
    }
}

public enum AXSettable: Sendable, Equatable {
    case string(String), bool(Bool), number(Double)
}

/// A read the app did not answer: its main thread is busy, it is waiting on a system prompt, or the element is gone.
public enum MacAXError: Error, Equatable {
    case cannotComplete(String)
    case elementGone(String)
}

/// The Accessibility calls xcd makes on another app, behind one protocol so tests use a fake.
public protocol AccessibilityAPI: AnyObject {
    var isTrusted: Bool { get }
    var screenCaptureAllowed: Bool { get }
    func isRunning(pid: Int32) -> Bool
    func application(pid: Int32) -> AXElement
    func string(_ attribute: String, of element: AXElement) throws -> String?
    func bool(_ attribute: String, of element: AXElement) throws -> Bool?
    func number(_ attribute: String, of element: AXElement) throws -> Double?
    /// `AXPosition` and `AXSize`, in screen points with a top-left origin.
    func rect(of element: AXElement) throws -> ScreenRect?
    func element(_ attribute: String, of element: AXElement) throws -> AXElement?
    func elements(_ attribute: String, of element: AXElement) throws -> [AXElement]
    func set(_ attribute: String, of element: AXElement, to value: AXSettable) -> Bool
    func actions(of element: AXElement) -> [String]
    func perform(_ action: String, on element: AXElement) -> Bool
    /// Posts the key down and up to the process alone; nothing reaches the frontmost app.
    func postKey(_ key: MacKey, to pid: Int32)
    func screenScale(containing rect: ScreenRect) -> Double
}

/// The real thing. Not `Sendable`: it holds `AXUIElement` values and lives inside one command.
public final class SystemAccessibility: AccessibilityAPI {
    /// Seconds an app gets to answer one request before it counts as not answering.
    public static let messagingTimeout: Float = 2
    /// Every element met in this command; an `AXElement`'s token is its index.
    private var table: [AXUIElement] = []
    /// The token each element already has. `AXUIElement` hashes with `CFHash` and compares with `CFEqual`, so an
    /// element read again (the engine re-reads the tree while it polls) gets its old token and the table stops growing.
    private var tokens: [AXUIElement: Int] = [:]

    public init() { /* the table starts empty */ }

    public var isTrusted: Bool { AXIsProcessTrusted() }
    public var screenCaptureAllowed: Bool { CGPreflightScreenCaptureAccess() }
    public func isRunning(pid: Int32) -> Bool { kill(pid, 0) == 0 }
    public func application(pid: Int32) -> AXElement { token(for: AXUIElementCreateApplication(pid)) }

    /// Every element gets the timeout when it is first met: it is per element, not inherited from the application's.
    func token(for element: AXUIElement) -> AXElement {
        if let known = tokens[element] { return AXElement(token: known) }
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        table.append(element)
        tokens[element] = table.count - 1
        return AXElement(token: table.count - 1)
    }

    func lookup(_ element: AXElement) -> AXUIElement? { table.indices.contains(element.token) ? table[element.token] : nil }

    func raw(_ attribute: String, of element: AXElement) throws -> CFTypeRef? {
        guard let target = lookup(element) else { throw MacAXError.elementGone(attribute) }
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(target, attribute as CFString, &value) {
        case .success: return value
        case .cannotComplete: throw MacAXError.cannotComplete(attribute)
        case .invalidUIElement: throw MacAXError.elementGone(attribute)
        default: return nil
        }
    }

    public func string(_ attribute: String, of element: AXElement) throws -> String? {
        let value = try raw(attribute, of: element)
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    public func bool(_ attribute: String, of element: AXElement) throws -> Bool? { (try raw(attribute, of: element) as? NSNumber)?.boolValue }
    public func number(_ attribute: String, of element: AXElement) throws -> Double? { (try raw(attribute, of: element) as? NSNumber)?.doubleValue }

    public func rect(of element: AXElement) throws -> ScreenRect? {
        guard let position = try raw(kAXPositionAttribute, of: element), let size = try raw(kAXSizeAttribute, of: element),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        // The type checks above make these casts safe. `as!` is not allowed, and Swift 6 rejects `as? AXValue`
        // ("conditional downcast to CoreFoundation type will always succeed"), so: a downcast of a verified AXValue.
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent) else { return nil }
        return ScreenRect(x: point.x, y: point.y, w: extent.width, h: extent.height)
    }

    public func element(_ attribute: String, of element: AXElement) throws -> AXElement? {
        guard let value = try raw(attribute, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return token(for: unsafeDowncast(value, to: AXUIElement.self))      // verified by the type check, as in `rect`
    }

    public func elements(_ attribute: String, of element: AXElement) throws -> [AXElement] {
        ((try raw(attribute, of: element)) as? [AXUIElement])?.map(token(for:)) ?? []
    }

    public func set(_ attribute: String, of element: AXElement, to value: AXSettable) -> Bool {
        guard let target = lookup(element) else { return false }
        let cf: CFTypeRef
        switch value {
        case .string(let text): cf = text as CFString
        case .bool(let flag): cf = flag ? kCFBooleanTrue : kCFBooleanFalse
        case .number(let number): cf = number as CFNumber
        }
        return AXUIElementSetAttributeValue(target, attribute as CFString, cf) == .success
    }

    public func actions(of element: AXElement) -> [String] {
        guard let target = lookup(element) else { return [] }
        var names: CFArray?
        guard AXUIElementCopyActionNames(target, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    public func perform(_ action: String, on element: AXElement) -> Bool {
        guard let target = lookup(element) else { return false }
        return AXUIElementPerformAction(target, action as CFString) == .success
    }

    public func postKey(_ key: MacKey, to pid: Int32) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: false) else { return }
        if let text = key.text {
            let units = Array(text.utf16)
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        down.postToPid(pid)
        usleep(5_000)
        up.postToPid(pid)
    }

    /// The backing scale of the screen under the rect's origin. Quartz measures from the top-left of the main
    /// screen; AppKit from its bottom-left, so y is flipped against the main screen's height.
    public func screenScale(containing rect: ScreenRect) -> Double {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = NSPoint(x: rect.x, y: mainHeight - rect.y)
        let screen = NSScreen.screens.first { NSPointInRect(point, $0.frame) } ?? NSScreen.main
        return Double(screen?.backingScaleFactor ?? 2)
    }
}
