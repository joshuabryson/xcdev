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

    /// Deletes the folders that are stale now, so one an `init` started using since `detect` is kept.
    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws {
        guard problem.action == .deleteScratch, let cache = problem.subject else { return }
        for path in InitScratch.stale(in: cache, now: env.now) {
            try FileManager.default.removeItem(atPath: path)
        }
    }
}
