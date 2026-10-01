import Foundation

/// Reads the built app out of `xcodebuild -showBuildSettings -json`.
public enum BuildSettings {
    /// The scheme's application target (preferring `preferredTarget`), or nil when the scheme builds no app.
    public static func app(from data: Data, preferredTarget: String?) throws -> AppProduct? {
        struct Entry: Decodable { let target: String; let buildSettings: [String: String] }
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            throw XcdError(.subprocessFailed, "could not parse `xcodebuild -showBuildSettings -json` output",
                           details: ["\(error)"])
        }
        let apps = entries.filter {
            ($0.buildSettings["PRODUCT_TYPE"] ?? "").hasPrefix("com.apple.product-type.application")
                || $0.buildSettings["WRAPPER_EXTENSION"] == "app"
        }
        guard let entry = apps.first(where: { $0.target == preferredTarget }) ?? apps.first else { return nil }
        let s = entry.buildSettings
        guard let dir = s["TARGET_BUILD_DIR"], let name = s["FULL_PRODUCT_NAME"], let bundleId = s["PRODUCT_BUNDLE_IDENTIFIER"],
              let executable = s["EXECUTABLE_NAME"], let platform = s["PLATFORM_NAME"] else { return nil }
        return AppProduct(path: dir + "/" + name, bundleId: bundleId, executableName: executable, platform: platform)
    }
}
