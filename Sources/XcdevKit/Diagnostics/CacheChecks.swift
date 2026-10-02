import Foundation

/// Scratch folders that interrupted `xcd init` runs left in `<home>/cache` (`InitScratch`), untouched for an hour.
/// The per-project package caches next to them are never touched.
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

/// `xcd init`'s Swift package caches (`PackageCache`) whose project is gone: the main checkout recorded in their
/// `root` file no longer exists. A cache with no record is reported for a person to judge, never deleted; one whose
/// lock is held is in use by an `init` and left alone.
public struct PackageCacheCheck: DoctorCheck {
    public let id = "package-caches"
    public init() {}

    public func detect(_ env: DoctorEnvironment) async -> [DoctorProblem] {
        let caches = PackageCache.all(in: env.globalPaths).filter { !Self.isBusy($0) }
        let orphaned = caches.compactMap { directory in PackageCache.owner(of: directory).map { (directory, $0) } }
            .filter { CheckoutPresence.of($0.1) == .missing }
        let sizes = await DiskUsage(runner: env.runner).bytes(of: orphaned.map(\.0))
        let gone = orphaned.map { directory, root in
            let size = sizes[directory].map { " (\(ByteText.format($0)))" } ?? ""
            return DoctorProblem(check: id, message: "the Swift package cache \(directory)\(size) belongs to \(root), which no longer exists",
                                 action: .deletePackageCache, fix: "delete it", subject: directory)
        }
        let unrecorded = caches.filter { PackageCache.owner(of: $0) == nil }.map { directory in
            DoctorProblem(check: id, message: "the Swift package cache \(directory) doesn't record which project it belongs to",
                          next: "if no project of yours uses it any more, delete \(Shell.quote(directory))", subject: directory)
        }
        return (gone + unrecorded).sorted { ($0.subject ?? "") < ($1.subject ?? "") }
    }

    public func inProgress(_ env: DoctorEnvironment) -> [String] {
        PackageCache.all(in: env.globalPaths).filter(Self.isBusy).map(Self.busyNote)
    }

    /// Deletes the cache while holding its lock, taken without waiting, and only if its project is still gone.
    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws {
        guard problem.action == .deletePackageCache, let directory = problem.subject else { return }
        let ran: Void? = try await FileLock.withLockIfFree(at: directory + ".lock") {
            guard let root = PackageCache.owner(of: directory), CheckoutPresence.of(root) == .missing else { return }
            try FileManager.default.removeItem(atPath: directory)
        }
        guard ran != nil else { throw DoctorLeftAlone(note: Self.busyNote(directory)) }
    }

    static func isBusy(_ directory: String) -> Bool { FileLock.isHeld(at: directory + ".lock") }

    static func busyNote(_ directory: String) -> String {
        "the Swift package cache \(directory) is in use by another `xcd init`; left alone"
    }
}
