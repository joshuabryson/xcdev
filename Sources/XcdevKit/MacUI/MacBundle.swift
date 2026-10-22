import Foundation
import Security

/// What a bundle's code signature says: the identifier it was signed with, and its
/// entitlements.
public struct MacSigningInfo: Sendable, Equatable {
    /// `kSecCodeInfoIdentifier`.
    public let identifier: String?
    /// An XML plist; nil when the signature carries no entitlements.
    public let entitlements: Data?

    public init(identifier: String?, entitlements: Data?) {
        self.identifier = identifier
        self.entitlements = entitlements
    }
}

/// Reads a bundle's signature, behind a protocol so tests use a fake.
public protocol MacBundleReading: Sendable {
    /// Nil when the bundle is not signed; throws on any other Security framework error.
    func signingInfo(of appPath: String) throws -> MacSigningInfo?
}

/// The Security framework's reading of a signature on disk. Nothing is run: the static code is only read.
public struct SystemBundleReader: MacBundleReading {
    public init() { /* stateless */ }

    public func signingInfo(of appPath: String) throws -> MacSigningInfo? {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: appPath) as CFURL, [], &code)
        var info: CFDictionary?
        if status == errSecSuccess, let code {
            status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        }
        if status == errSecCSUnsigned { return nil }
        guard status == errSecSuccess, let dictionary = info as? [String: Any] else {
            throw XcdError(.internalError, "cannot read the signature of \(appPath): OSStatus \(status)",
                           next: "run `codesign -dv \(Shell.quote(appPath))` to see what is wrong")
        }
        // An unsigned bundle answers errSecSuccess with nothing but `main-executable`: no identifier, no signature.
        // The entitlements are `entitlements-dict` (measured 2026-10-21).
        guard let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String else { return nil }
        guard let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            return MacSigningInfo(identifier: identifier, entitlements: nil)
        }
        let xml = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        return MacSigningInfo(identifier: identifier, entitlements: xml)
    }
}

/// What xcd must know about a built Mac app before `isolation: suffix` copies it.
public struct MacBundleFacts: Sendable, Equatable {
    public let path: String
    /// `CFBundleIdentifier` from `Contents/Info.plist`; nil when the plist or the key is missing, or the key is empty.
    public let bundleId: String?
    public let hasInfoPlist: Bool
    /// Nil when the bundle is not signed.
    public let signing: MacSigningInfo?
    /// Paths relative to the bundle, sorted.
    public let nestedBundles: [String]
    /// Whether `Contents/embedded.provisionprofile` exists.
    public let hasProfile: Bool

    public init(path: String, bundleId: String?, hasInfoPlist: Bool, signing: MacSigningInfo?, nestedBundles: [String],
                hasProfile: Bool) {
        self.path = path
        self.bundleId = bundleId
        self.hasInfoPlist = hasInfoPlist
        self.signing = signing
        self.nestedBundles = nestedBundles
        self.hasProfile = hasProfile
    }
}

public enum MacBundle {
    /// Folders whose every entry is a bundle that must share the app's identifier prefix.
    static let nestingFolders = ["Contents/PlugIns", "Contents/XPCServices", "Contents/Library/LoginItems"]

    public static func facts(of appPath: String, reader: any MacBundleReading) throws -> MacBundleFacts {
        let plist = infoPlist(of: appPath)
        // A folder with no Info.plist is no bundle to the Security framework (errSecCSBadBundleFormat), and the
        // refusal names the missing plist first, so its signature is not asked for.
        var signing: MacSigningInfo?
        if plist != nil { signing = try reader.signingInfo(of: appPath) }
        let bundleId = (plist?["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return MacBundleFacts(path: appPath, bundleId: bundleId, hasInfoPlist: plist != nil, signing: signing,
                              nestedBundles: nestedBundles(in: appPath),
                              hasProfile: Disk.exists(appPath + "/Contents/embedded.provisionprofile"))
    }

    /// Every entry of the nesting folders but Finder's dot files, and every `.app` under `Contents` at any depth.
    static func nestedBundles(in appPath: String) -> [String] {
        var found = Set(nestingFolders.flatMap { folder in
            Disk.names(in: appPath + "/" + folder).filter { !$0.hasPrefix(".") }.map { folder + "/" + $0 }
        })
        // `Disk.files` lists files only and does not follow links, so an embedded app is found through its files.
        for file in Disk.files(under: appPath + "/Contents") {
            let parts = file.split(separator: "/").map(String.init)
            for end in parts.indices.dropLast() where parts[end].hasSuffix(".app") {
                found.insert("Contents/" + parts[...end].joined(separator: "/"))
            }
        }
        return found.sorted()
    }

    /// The bundle's Info.plist, binary or XML; nil when it is missing or is not a dictionary.
    static func infoPlist(of appPath: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: appPath + "/Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
