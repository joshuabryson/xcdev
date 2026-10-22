import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// What xcd reads from a built Mac app before `isolation: suffix` copies it.
@Suite struct MacBundleTests {
    let base = NSTemporaryDirectory() + "xcd-bundle-\(UUID().uuidString)"
    var app: String { base + "/App.app" }

    /// A bundle at `path`: `Contents/Info.plist` from `plist` in `format` (none when nil), and an empty file at each
    /// of `files`, relative to the bundle.
    static func makeBundle(at path: String, plist: [String: Any]?, format: PropertyListSerialization.PropertyListFormat = .xml,
                           files: [String] = ["Contents/MacOS/App"]) throws {
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        if let plist {
            try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
                .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        }
        for file in files {
            let full = path + "/" + file
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data().write(to: URL(fileURLWithPath: full))
        }
    }

    /// Entitlements as a signature carries them.
    static func entitlements(_ values: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    static func sandboxed(_ identifier: String = "dev.x.App") throws -> MacSigningInfo {
        MacSigningInfo(identifier: identifier, entitlements: try entitlements(["com.apple.security.app-sandbox": true]))
    }

    @Test func factsReadTheIdentifierTheSignatureNestedBundlesAndTheProfile() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try Self.makeBundle(at: app, plist: ["CFBundleIdentifier": "dev.x.App"], files: [
            "Contents/MacOS/App", "Contents/embedded.provisionprofile", "Contents/PlugIns/Share.appex/Contents/Info.plist",
            "Contents/XPCServices/Helper.xpc/Contents/Info.plist", "Contents/Library/LoginItems/Agent.app/Contents/Info.plist",
            "Contents/Helpers/Tool.app/Contents/MacOS/Tool", "Contents/Frameworks/Kit.framework/Versions/A/Kit",
            "Contents/PlugIns/.DS_Store",
        ])
        let reader = FakeBundleReader()
        let signing = try Self.sandboxed()
        reader.set(signing, for: app)
        let facts = try MacBundle.facts(of: app, reader: reader)
        #expect(facts == MacBundleFacts(path: app, bundleId: "dev.x.App", hasInfoPlist: true, signing: signing,
                                        nestedBundles: ["Contents/Helpers/Tool.app", "Contents/Library/LoginItems/Agent.app",
                                                        "Contents/PlugIns/Share.appex", "Contents/XPCServices/Helper.xpc"],
                                        hasProfile: true))
    }

    /// Xcode writes a binary Info.plist; a framework and resources are not nested bundles.
    @Test func aBinaryInfoPlistReadsLikeAnXMLOneAndAPlainAppHasNothingNested() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try Self.makeBundle(at: app, plist: ["CFBundleIdentifier": "dev.x.App"], format: .binary,
                            files: ["Contents/MacOS/App", "Contents/Resources/en.lproj/Main.strings", "Contents/Frameworks/Kit.framework/Kit"])
        let facts = try MacBundle.facts(of: app, reader: FakeBundleReader())
        #expect(facts.bundleId == "dev.x.App" && facts.hasInfoPlist && facts.nestedBundles.isEmpty && !facts.hasProfile)
    }

    @Test func anExtensionKitExtensionIsNested() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try Self.makeBundle(at: app, plist: ["CFBundleIdentifier": "dev.x.App"],
                            files: ["Contents/MacOS/App", "Contents/Extensions/Share.appex/Contents/MacOS/Share", "Contents/Extensions/Host.appextensionpoints"])
        #expect(MacBundle.nestedBundles(in: app) == ["Contents/Extensions/Share.appex"])
    }

    @Test func anAppInsideAFrameworkIsNotNested() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try Self.makeBundle(at: app, plist: ["CFBundleIdentifier": "dev.x.App"],
                            files: ["Contents/MacOS/App", "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater"])
        #expect(MacBundle.nestedBundles(in: app).isEmpty)
    }

    @Test func anUnsignedBundleHasNoSigningAndAPlistlessOneIsNotAskedForIt() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let bare = base + "/Bare.app"
        try Self.makeBundle(at: app, plist: ["CFBundleIdentifier": "dev.x.App"])
        try Self.makeBundle(at: bare, plist: nil)
        let reader = FakeBundleReader()
        #expect(try MacBundle.facts(of: app, reader: reader).signing == nil)
        let plistless = try MacBundle.facts(of: bare, reader: reader)
        #expect(!plistless.hasInfoPlist && plistless.bundleId == nil && plistless.signing == nil)
        #expect(reader.calls == [app])
    }

    @Test func aSignatureThatCannotBeReadStopsTheFacts() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try Self.makeBundle(at: app, plist: ["CFBundleIdentifier": "dev.x.App"])
        let reader = FakeBundleReader()
        reader.failing = [app]
        let error = #expect(throws: XcdError.self) { try MacBundle.facts(of: app, reader: reader) }
        #expect(error?.code == .internalError)
    }

    /// The real reader on a real ad-hoc signature: a copy of /usr/bin/true as the executable, signed with codesign.
    @Test func theSystemReaderReadsAnAdHocSignatureAndItsEntitlements() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try Self.makeBundle(at: app, plist: ["CFBundleIdentifier": "dev.x.App", "CFBundleExecutable": "App", "CFBundlePackageType": "APPL"],
                            files: [])
        try FileManager.default.createDirectory(atPath: app + "/Contents/MacOS", withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app + "/Contents/MacOS/App")
        let file = base + "/App.entitlements"
        try Self.entitlements(["com.apple.security.app-sandbox": true]).write(to: URL(fileURLWithPath: file))
        try await SystemProcessRunner().runChecked(Invocation("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", file, app]))
        let signing = try #require(try SystemBundleReader().signingInfo(of: app))
        #expect(signing.identifier == "dev.x.App" && MacEntitlements.isSandboxed(signing.entitlements))
        #expect(MacEntitlements.keys(try #require(signing.entitlements)) == ["com.apple.security.app-sandbox"])
    }

    /// An Info.plist and no executable: nothing is signed. No Info.plist: no bundle, an error naming codesign.
    @Test func theSystemReaderCallsANothingSignedBundleUnsignedAndAPlistlessFolderAnError() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let bare = base + "/Bare.app"
        try Self.makeBundle(at: app, plist: ["CFBundleIdentifier": "dev.x.App", "CFBundleExecutable": "App"], files: [])
        try Self.makeBundle(at: bare, plist: nil, files: [])
        #expect(try SystemBundleReader().signingInfo(of: app) == nil)
        let error = #expect(throws: XcdError.self) { try SystemBundleReader().signingInfo(of: bare) }
        #expect(error?.code == .internalError && error?.message.hasPrefix("cannot read the signature of \(bare): OSStatus -") == true)
        #expect(error?.next == "run `codesign -dv \(Shell.quote(bare))` to see what is wrong")
    }
}

/// Which entitlements an ad-hoc copy keeps and which refuse `suffix`.
@Suite struct MacEntitlementsTests {
    @Test func keysAreSortedAndGarbageHasNoneAndCannotBeKept() throws {
        let plist = try MacBundleTests.entitlements(["com.apple.security.network.client": true, "com.apple.security.app-sandbox": true])
        #expect(MacEntitlements.keys(plist) == ["com.apple.security.app-sandbox", "com.apple.security.network.client"])
        #expect(MacEntitlements.keys(Data("not a plist".utf8)).isEmpty)
        let error = #expect(throws: XcdError.self) { try MacEntitlements.kept(Data("not a plist".utf8)) }
        #expect(error?.code == .internalError && error?.next?.contains("codesign -d --entitlements") == true)
    }

    @Test func keptKeepsOnlyTheSecurityKeysWithTheirValues() throws {
        let plist = try MacBundleTests.entitlements([
            "com.apple.security.app-sandbox": true, "com.apple.security.files.user-selected.read-write": true,
            "com.apple.security.get-task-allow": true, "com.apple.security.application-groups": ["group.dev.x"],
            "com.apple.security.temporary-exception.files.absolute-path.read-only": ["/Library/Fonts/"],
            "com.apple.application-identifier": "ABCDE12345.dev.x.App", "com.apple.developer.team-identifier": "ABCDE12345",
        ])
        let kept = try MacEntitlements.kept(plist)
        let groups = MacEntitlements.groupsAreRefused ? [] : ["com.apple.security.application-groups"]
        #expect(MacEntitlements.keys(kept) == (["com.apple.security.app-sandbox"] + groups + [
            "com.apple.security.files.user-selected.read-write", "com.apple.security.get-task-allow",
            "com.apple.security.temporary-exception.files.absolute-path.read-only",
        ]))
        let values = try #require(try PropertyListSerialization.propertyList(from: kept, format: nil) as? [String: Any])
        #expect(values["com.apple.security.temporary-exception.files.absolute-path.read-only"] as? [String] == ["/Library/Fonts/"])
        #expect(String(decoding: kept, as: UTF8.self).hasPrefix("<?xml"))
    }

    @Test func refusedNamesDeveloperKeysAndKeychainGroupsButNotTheTeamIdentifier() {
        let keys = ["keychain-access-groups", "com.apple.developer.team-identifier", "com.apple.security.app-sandbox",
                    "com.apple.developer.icloud-container-identifiers", "com.apple.application-identifier",
                    "com.apple.developer.associated-domains", "com.apple.security.application-groups"]
        let groups = MacEntitlements.groupsAreRefused ? ["com.apple.security.application-groups"] : []
        #expect(MacEntitlements.refused(keys) == ["com.apple.developer.associated-domains", "com.apple.developer.icloud-container-identifiers"]
            + groups + ["keychain-access-groups"])
    }

    @Test func sandboxedOnlyWhenTheSandboxKeyIsTrue() throws {
        #expect(MacEntitlements.isSandboxed(try MacBundleTests.entitlements(["com.apple.security.app-sandbox": true])))
        #expect(!MacEntitlements.isSandboxed(try MacBundleTests.entitlements(["com.apple.security.app-sandbox": false])))
        #expect(!MacEntitlements.isSandboxed(try MacBundleTests.entitlements(["com.apple.security.network.client": true])))
        #expect(!MacEntitlements.isSandboxed(nil))
    }
}
