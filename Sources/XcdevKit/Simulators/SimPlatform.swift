public enum SimPlatform: String, Sendable {
    case iOS, watchOS, tvOS, visionOS

    public init?(productFamily: String) {
        switch productFamily {
        case "iPhone", "iPad": self = .iOS
        case "Apple Watch": self = .watchOS
        case "Apple TV": self = .tvOS
        case "Apple Vision": self = .visionOS
        default: return nil
        }
    }

    /// The `platform` value simctl reports for runtimes ("xrOS" for visionOS).
    public var runtimePlatform: String { self == .visionOS ? "xrOS" : rawValue }
}
