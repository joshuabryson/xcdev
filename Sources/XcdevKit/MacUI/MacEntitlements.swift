import Foundation

/// The entitlements an ad-hoc copy keeps, and the ones that need a provisioning profile.
public enum MacEntitlements {
    static let sandbox = "com.apple.security.app-sandbox"
    static let groups = "com.apple.security.application-groups"
    /// App groups are kept unless an ad-hoc copy was found unable to use them. True, measured on
    /// 2026-10-21: a write into the group container failed with EPERM (NSCocoaErrorDomain 513), for the ad-hoc
    /// product and for its copy.
    static let groupsAreRefused = true

    /// The entitlement names, sorted; empty when `plist` is not a dictionary plist.
    public static func keys(_ plist: Data) -> [String] {
        dictionary(plist)?.keys.sorted() ?? []
    }

    /// Whether `com.apple.security.app-sandbox` is true.
    public static func isSandboxed(_ plist: Data?) -> Bool {
        plist.flatMap(dictionary)?[sandbox] as? Bool == true
    }

    /// The keys an ad-hoc signature cannot carry, sorted: every `com.apple.developer.*` key but the team identifier,
    /// which is dropped with the team signature, and `keychain-access-groups`.
    public static func refused(_ keys: [String]) -> [String] {
        keys.filter { key in
            (key.hasPrefix("com.apple.developer.") && key != "com.apple.developer.team-identifier")
                || key == "keychain-access-groups" || (groupsAreRefused && key == groups)
        }.sorted()
    }

    /// The `com.apple.security.*` entries with their values, as an XML plist: the sandbox, file and network access,
    /// `get-task-allow`, temporary exceptions, and app groups. `com.apple.application-identifier` and
    /// `com.apple.developer.team-identifier` are left out: they belong to the team signature the copy no longer has.
    public static func kept(_ plist: Data) throws -> Data {
        guard let entitlements = dictionary(plist) else {
            throw XcdError(.internalError, "the built app's entitlements are not a property list xcd can read",
                           next: "run `codesign -d --entitlements - --xml <the built app>` to see them")
        }
        let kept = entitlements.filter { $0.key.hasPrefix("com.apple.security.") && !(groupsAreRefused && $0.key == groups) }
        return try PropertyListSerialization.data(fromPropertyList: kept, format: .xml, options: 0)
    }

    static func dictionary(_ plist: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any]
    }
}
