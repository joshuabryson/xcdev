import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// What `isolation: suffix` refuses before it copies anything.
@Suite struct MacIsolationRefusalTests {
    static let path = "/w/.xcdev/DerivedData/Build/Products/Debug/App.app"
    static let next = "set devices.mac.isolation: shared in .xcdev.yml, or remove the key; every worktree's copy then shares the app's data"

    static func facts(bundleId: String? = "dev.x.App", signing: MacSigningInfo?, nested: [String] = []) -> MacBundleFacts {
        MacBundleFacts(path: path, bundleId: bundleId, hasInfoPlist: true, signing: signing, nestedBundles: nested, hasProfile: false)
    }

    static func signed(_ entitlements: [String: Any]) throws -> MacSigningInfo {
        MacSigningInfo(identifier: "dev.x.App", entitlements: try MacBundleTests.entitlements(entitlements))
    }

    /// The refusal's message, or nil when the bundle passes.
    static func refusal(_ facts: MacBundleFacts) -> String? {
        do {
            try MacIsolationRefusal.check(facts, device: "mac")
            return nil
        } catch {
            return (error as? XcdError)?.message ?? "\(error)"
        }
    }

    /// No plist, a plist without the key, and an empty identifier, read from real bundles.
    @Test func aBundleWithoutAnIdentifierIsRefused() throws {
        let base = NSTemporaryDirectory() + "xcd-refusal-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let reader = FakeBundleReader()
        for (name, plist) in [("None.app", nil), ("Keyless.app", ["CFBundleName": "App"]), ("Empty.app", ["CFBundleIdentifier": ""])] as [(String, [String: Any]?)] {
            let app = base + "/" + name
            try MacBundleTests.makeBundle(at: app, plist: plist)
            reader.set(try MacBundleTests.sandboxed(), for: app)
            #expect(Self.refusal(try MacBundle.facts(of: app, reader: reader))
                == "the built app at \(app) has no Info.plist with a CFBundleIdentifier, so xcd cannot give this worktree's copy its own identity")
        }
    }

    @Test func anUnsignedBundleIsRefused() {
        #expect(Self.refusal(Self.facts(signing: nil))
            == "the built app at \(Self.path) is not signed, so xcd cannot re-sign a copy with its entitlements")
    }

    @Test func aDeveloperEntitlementIsRefusedNamingTheKeys() throws {
        let signing = try Self.signed(["com.apple.security.app-sandbox": true, "keychain-access-groups": ["T.dev.x"],
                                       "com.apple.developer.icloud-services": ["CloudKit"], "com.apple.developer.team-identifier": "T"])
        #expect(Self.refusal(Self.facts(signing: signing)) == "the built app's entitlements need a provisioning profile, which an ad-hoc copy "
            + "cannot carry: com.apple.developer.icloud-services, keychain-access-groups")
    }

    @Test func aNestedBundleIsRefusedNamingIt() throws {
        let facts = Self.facts(signing: try MacBundleTests.sandboxed(), nested: ["Contents/PlugIns/Share.appex", "Contents/XPCServices/Helper.xpc"])
        #expect(Self.refusal(facts) == "the built app embeds bundles that must share its identifier, which xcd does not re-identify: "
            + "Contents/PlugIns/Share.appex, Contents/XPCServices/Helper.xpc")
    }

    /// The team keys of a team-signed build are dropped by the copy, not refused.
    @Test func aPlainSandboxedAppPassesAndSoDoesATeamSignedOne() throws {
        #expect(Self.refusal(Self.facts(signing: try MacBundleTests.sandboxed())) == nil)
        #expect(Self.refusal(Self.facts(signing: MacSigningInfo(identifier: "dev.x.App", entitlements: nil))) == nil)
        let team = try Self.signed(["com.apple.security.app-sandbox": true, "com.apple.application-identifier": "T.dev.x.App",
                                    "com.apple.developer.team-identifier": "T", "com.apple.security.get-task-allow": true])
        #expect(Self.refusal(Self.facts(signing: team)) == nil)
    }

    /// One refusal at a time, in a fixed order, each `config_invalid` (exit 2) with the same way out.
    @Test func refusalsCarryTheConfigInvalidCodeAndTheSharedNext() throws {
        let worst = MacBundleFacts(path: Self.path, bundleId: nil, hasInfoPlist: false, signing: nil,
                                   nestedBundles: ["Contents/PlugIns/Share.appex"], hasProfile: true)
        let error = #expect(throws: XcdError.self) { try MacIsolationRefusal.check(worst, device: "mac") }
        #expect(error?.code == .configInvalid && error?.code.exitCode == 2 && error?.next == Self.next)
        #expect(error?.message.contains("no Info.plist") == true)
        #expect(Self.refusal(Self.facts(signing: nil, nested: ["Contents/PlugIns/Share.appex"]))?.contains("is not signed") == true)
    }
}
