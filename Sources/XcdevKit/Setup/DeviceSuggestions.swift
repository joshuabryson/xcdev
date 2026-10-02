/// The kinds of device `xcd init` can add. The raw value is the device's name in .xcdev.yml, and the case
/// order is the order devices are written and asked about.
public enum DeviceRole: String, Codable, Sendable, CaseIterable {
    case iphone, ipad, watch, vision, tv, mac

    public var productFamily: String? {
        switch self {
        case .iphone: return "iPhone"
        case .ipad: return "iPad"
        case .watch: return "Apple Watch"
        case .vision: return "Apple Vision"
        case .tv: return "Apple TV"
        case .mac: return nil
        }
    }

    public var platform: AppPlatform {
        switch self {
        case .iphone, .ipad: return .iOS
        case .watch: return .watchOS
        case .vision: return .visionOS
        case .tv: return .tvOS
        case .mac: return .macOS
        }
    }

    /// "iPhone", "an iPhone".
    public var noun: String {
        switch self {
        case .iphone: return "iPhone"
        case .ipad: return "iPad"
        case .watch: return "Apple Watch"
        case .vision: return "Apple Vision Pro"
        case .tv: return "Apple TV"
        case .mac: return "Mac"
        }
    }

    public var withArticle: String { "an " + noun }
}

/// Device types to offer for a role, from `simctl list -j`.
public struct DeviceChoices: Sendable, Equatable {
    /// Best first, at most `limit`.
    public let types: [String]
    /// The newest installed runtime for the role's platform, or nil when none is installed.
    public let runtime: String?
}

public enum DeviceSuggestions {
    /// simctl lists each family's device types newest first, so that order is kept, with variants of another
    /// type ("iPad Pro 13-inch (M5) (16GB)", "Apple TV 4K (3rd generation) (at 1080p)") moved after the plain ones.
    /// Only types the newest runtime supports are offered; with no runtime installed, every type of the family is.
    public static func choices(for role: DeviceRole, catalog: SimCatalog, limit: Int = 5) -> DeviceChoices {
        guard let family = role.productFamily, let simPlatform = SimPlatform(productFamily: family) else {
            return DeviceChoices(types: [], runtime: nil)
        }
        let runtime = catalog.runtimes
            .filter { $0.isAvailable && $0.platform == simPlatform.runtimePlatform }
            .max { (Version($0.version) ?? .zero) < (Version($1.version) ?? .zero) }
        let names = catalog.deviceTypes
            .filter { $0.productFamily == family && (runtime?.supports($0) ?? true) }
            .map(\.name)
        let isVariant = { (name: String) in names.contains { name.hasPrefix($0 + " (") } }
        let ordered = names.filter { !isVariant($0) } + names.filter(isVariant)
        return DeviceChoices(types: Array(ordered.prefix(limit)), runtime: runtime?.name)
    }
}
