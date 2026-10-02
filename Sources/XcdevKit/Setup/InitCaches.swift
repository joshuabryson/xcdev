import Foundation

/// The `init-<UUID>` scratch folders `xcd init` makes under `<home>/cache` for xcodebuild's DerivedData and package
/// checkouts and SwiftPM's build folders. A run
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
