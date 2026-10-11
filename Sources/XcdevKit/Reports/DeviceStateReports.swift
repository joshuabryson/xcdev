public struct DeviceStateReport: Reportable {
    public let action: String
    public let device: String
    public let udid: String
    public let worktree: String

    public var text: String { "\(action)  device=\(device)  udid=\(udid)" }
    public var envelopeWorktree: String? { worktree }
}

/// `xcd sim pasteboard get`: the text alone, so `$(xcd sim pasteboard get)` works.
public struct PasteboardReport: Reportable {
    public let device: String
    public let udid: String
    public let text: String
    public let worktree: String

    public var envelopeWorktree: String? { worktree }
}

/// `xcd sim text-size`: the size the device has now, whether this command set it or only read it.
public struct TextSizeReport: Reportable {
    public let size: String
    /// Whether this command set the size.
    public let changed: Bool
    public let device: String
    public let udid: String
    public let worktree: String

    public var text: String { "\(changed ? "set text size to" : "text size is") \(size)  device=\(device)  udid=\(udid)" }
    public var envelopeWorktree: String? { worktree }
}

/// `xcd sim container`: the path alone, so `ls "$(xcd sim container)"` works. For `groups`, a line per app group:
/// its identifier, a tab, and its path.
public struct ContainerReport: Reportable {
    public let device: String
    public let udid: String
    public let bundleId: String
    /// `data`, `app`, `groups`, or an app group's identifier.
    public let container: String
    /// Nil for `groups`.
    public let path: String?
    /// Each app group's path by its identifier; only for `groups`.
    public let groups: [String: String]?
    public let worktree: String

    public var text: String {
        guard let groups else { return path ?? "" }
        if groups.isEmpty { return "\(bundleId) has no app groups" }
        return groups.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktree }
}
