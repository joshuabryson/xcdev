import Foundation

/// Scratch folders that interrupted `xcd init` runs left in `<home>/cache` (`InitScratch`), untouched for an hour.
/// Package caches of earlier versions next to them are `PackageCacheCheck`'s.
public struct InitScratchCheck: DoctorCheck {
    public let id = "init-scratch"
    public init() {}

    public func detect(_ env: DoctorEnvironment) async -> [DoctorProblem] {
        let cache = env.globalPaths.cacheDirectory
        let stale = InitScratch.stale(in: cache, now: env.now)
        guard !stale.isEmpty else { return [] }
        let bytes = await DiskUsage(runner: env.runner).bytes(of: stale).values.reduce(0, +)
        let count = stale.count == 1 ? "1 scratch folder" : "\(stale.count) scratch folders"
        return [DoctorProblem(check: id, message: "\(count) of interrupted `xcd init` runs, older than an hour, use "
                                  + "\(bytes > 0 ? ByteText.format(bytes) : "an unknown amount of space") in \(cache)",
                              action: .deleteScratch, fix: "delete them", subject: cache)]
    }

    /// Deletes the folders that are stale now, so one an `init` started using since `detect` is kept. Tries every
    /// folder, then names the ones it couldn't delete.
    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws {
        guard problem.action == .deleteScratch, let cache = problem.subject else { return }
        var failures: [String] = []
        for path in InitScratch.stale(in: cache, now: env.now) {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                failures.append("\(path): \((error as NSError).localizedDescription)")
            }
        }
        guard failures.isEmpty else {
            throw XcdError(.internalError, "could not delete \(failures.count) of the scratch folders",
                           next: "delete them by hand: " + failures.joined(separator: "; "))
        }
    }
}

/// Swift package caches that earlier versions of `xcd init` kept for each project in `<home>/cache/packages/<key>`
/// (locked by `<key>.lock` while in use), often a gigabyte each. `init` now reads the project files instead and never
/// uses them, so each is reclaimable; one whose lock is held belongs to an older xcd still running and is left alone.
public struct PackageCacheCheck: DoctorCheck {
    public let id = "package-caches"
    public init() {}

    /// Every cache folder under `<home>/cache/packages`, sorted (lock files left out).
    static func all(in globalPaths: GlobalPaths) -> [String] {
        let packages = globalPaths.cacheDirectory + "/packages"
        return ((try? FileManager.default.contentsOfDirectory(atPath: packages)) ?? []).sorted().compactMap { name in
            var isDirectory: ObjCBool = false
            let path = packages + "/" + name
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? path : nil
        }
    }

    public func detect(_ env: DoctorEnvironment) async -> [DoctorProblem] {
        let caches = Self.all(in: env.globalPaths).filter { !Self.isBusy($0) }
        let sizes = await DiskUsage(runner: env.runner).bytes(of: caches)
        return caches.map { directory in
            let size = sizes[directory].map { " (\(ByteText.format($0)))" } ?? ""
            return DoctorProblem(check: id, message: "the Swift package cache \(directory)\(size) is left over from an earlier "
                                     + "version of xcd; `xcd init` no longer keeps one",
                                 action: .deletePackageCache, fix: "delete it", subject: directory)
        }
    }

    public func inProgress(_ env: DoctorEnvironment) -> [String] {
        Self.all(in: env.globalPaths).filter(Self.isBusy).map(Self.busyNote)
    }

    /// Deletes the cache and its lock file while holding the lock, taken without waiting, then the `packages`
    /// folder once it is empty.
    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws {
        guard problem.action == .deletePackageCache, let directory = problem.subject else { return }
        let lock = directory + ".lock"
        let ran: Void? = try await FileLock.withLockIfFree(at: lock) {
            try FileManager.default.removeItem(atPath: directory)
            // Unlinking a lock file while holding it is safe here: an earlier xcd that opens the path afterwards
            // creates a new file and locks that, and it finds no cache to use, so nothing relies on the old one.
            try? FileManager.default.removeItem(atPath: lock)
        }
        guard ran != nil else { throw DoctorLeftAlone(note: Self.busyNote(directory)) }
        let packages = (directory as NSString).deletingLastPathComponent
        if (try? FileManager.default.contentsOfDirectory(atPath: packages))?.isEmpty == true {
            try? FileManager.default.removeItem(atPath: packages)
        }
    }

    static func isBusy(_ directory: String) -> Bool { FileLock.isHeld(at: directory + ".lock") }

    static func busyNote(_ directory: String) -> String {
        "the Swift package cache \(directory) is in use by an earlier version's `xcd init`; left alone"
    }
}
