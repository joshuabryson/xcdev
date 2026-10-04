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
