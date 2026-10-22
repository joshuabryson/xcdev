import Foundation

/// What `isolation: suffix` cannot copy, refused before anything is copied: the copy would not get its
/// own identity, or would not be the app.
public enum MacIsolationRefusal {
    public static func check(_ facts: MacBundleFacts, device: String) throws {
        guard let reason = reason(facts) else { return }
        throw XcdError(.configInvalid, reason,
                       next: "set devices.\(device).isolation: shared in .xcdev.yml, or remove the key; every worktree's copy then shares the app's data")
    }

    /// The first refusal in a fixed order, or nil when the bundle can be copied.
    static func reason(_ facts: MacBundleFacts) -> String? {
        guard facts.hasInfoPlist, facts.bundleId != nil else {
            return "the built app at \(facts.path) has no Info.plist with a CFBundleIdentifier, "
                + "so xcd cannot give this worktree's copy its own identity"
        }
        // A signing read with no identifier is an unsigned bundle too.
        guard let signing = facts.signing, signing.identifier != nil else {
            return "the built app at \(facts.path) is not signed, so xcd cannot re-sign a copy with its entitlements"
        }
        let refused = MacEntitlements.refused(signing.entitlements.map(MacEntitlements.keys) ?? [])
        guard refused.isEmpty else {
            return "the built app's entitlements need a provisioning profile, which an ad-hoc copy cannot carry: "
                + refused.joined(separator: ", ")
        }
        guard facts.nestedBundles.isEmpty else {
            return "the built app embeds bundles that must share its identifier, which xcd does not re-identify: "
                + facts.nestedBundles.joined(separator: ", ")
        }
        return nil
    }
}
