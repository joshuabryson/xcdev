import Foundation

/// The URL schemes an app registers (`CFBundleURLTypes` in its Info.plist).
public enum AppSchemes {
    /// The schemes the built app registers, as its Info.plist spells them. Nil when the plist cannot be read, which
    /// callers treat as "unknown", not as "none".
    public static func registered(by product: AppProduct) -> [String]? {
        // An iOS app keeps its Info.plist at the top of the bundle; a Mac app keeps it under Contents.
        let path = product.path + (product.isMac ? "/Contents/Info.plist" : "/Info.plist")
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let types = plist["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    }

    /// Whether the app registers `scheme`. The system matches schemes without regard to case.
    public static func registers(_ scheme: String, in registered: [String]) -> Bool {
        registered.contains { $0.lowercased() == scheme.lowercased() }
    }
}
