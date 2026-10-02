import CryptoKit
import Foundation

/// Where `xcd init` keeps a project's Swift package checkouts between runs: `<home>/cache/packages/<key>/SourcePackages`,
/// locked by `<home>/cache/packages/<key>.lock` while xcodebuild uses it. A second run finds the checkouts and
/// fetches only what changed, instead of cloning every package again (1.2 GB for a Firebase app).
public struct PackageCache: Sendable, Equatable {
    public let directory: String
    public let lockPath: String

    public init(globalPaths: GlobalPaths, root: String) {
        let base = globalPaths.cacheDirectory + "/packages/" + Self.key(for: root)
        directory = base
        lockPath = base + ".lock"
    }

    /// For `-clonedSourcePackagesDirPath`.
    public var sourcePackages: String { directory + "/SourcePackages" }

    /// `<folder name>-<first 16 hex digits of the SHA-256 of root>`, e.g. "SampleApp-1f2e3d4c5b6a7980": readable, stable,
    /// and different for two checkouts with the same folder name. Characters other than letters, digits, `.`, `_`, and
    /// `-` in the name become `-`.
    public static func key(for root: String) -> String {
        let hash = SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let name = String(String.UnicodeScalarView(URL(fileURLWithPath: root).lastPathComponent.unicodeScalars.map {
            $0.isASCII && allowed.contains($0) ? $0 : "-"
        })).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty ? String(hash) : name + "-" + hash
    }
}

/// The `init-<UUID>` scratch folders `xcd init` makes under `<home>/cache` for xcodebuild's DerivedData. A run
/// deletes its own when it ends, but not when it is killed (Ctrl-C skips the cleanup), so `init` and `xcd doctor`
/// delete the ones untouched for an hour. No run lasts that long: listing has 10 minutes and each scheme's build
/// settings 2 more.
public enum InitScratch {
    public static let prefix = "init-"
    public static let staleAfter: TimeInterval = 3600

    /// A new scratch folder's path (not created).
    public static func make(in cacheDirectory: String) -> String {
        cacheDirectory + "/" + prefix + UUID().uuidString
    }

    /// Scratch folders in `cacheDirectory` last modified more than an hour before `now`. Only folders named `init-`
    /// and a UUID count; anything else there is left alone.
    public static func stale(in cacheDirectory: String, now: Date) -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: cacheDirectory)) ?? []).sorted().compactMap { name in
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { return nil }
            let path = cacheDirectory + "/" + name
            guard let attributes = try? fm.attributesOfItem(atPath: path), attributes[.type] as? FileAttributeType == .typeDirectory,
                  let modified = attributes[.modificationDate] as? Date, now.timeIntervalSince(modified) > staleAfter else { return nil }
            return path
        }
    }

    /// Deletes the stale scratch folders, ignoring errors. Returns the ones it deleted.
    @discardableResult
    public static func removeStale(in cacheDirectory: String, now: Date) -> [String] {
        stale(in: cacheDirectory, now: now).filter { (try? FileManager.default.removeItem(atPath: $0)) != nil }
    }
}
