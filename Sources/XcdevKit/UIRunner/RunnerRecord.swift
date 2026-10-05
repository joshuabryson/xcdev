import Darwin
import Foundation

/// A started UI runner, kept in `.xcdev/ui-runner-<device>.json` so later xcd commands can use or stop it.
public struct RunnerRecord: Codable, Sendable, Equatable {
    public var device: String
    public var udid: String
    /// The detached `xcodebuild test-without-building`.
    public var process: ProcessIdentity
    public var token: String
    /// Nil until the runner has written its ready file.
    public var port: Int?
    public var runnerKey: String
    public var log: String
    public var readyFile: String
    public var startedAt: Date
    /// When this runner and its predecessors were restarted, for the crash-loop rule.
    public var restarts: [Date]
    /// Set when it restarted twice within a minute; cleared by `xcd ui stop`.
    public var failed: Bool
}

extension WorktreePaths {
    public func runnerFile(device: String) -> String { stateDirectory + "/ui-runner-\(device).json" }
    public func runnerLog(device: String) -> String { logs + "/ui-runner-\(device).log" }

    /// Every runner record in this worktree, sorted.
    public var runnerFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: stateDirectory)) ?? [])
            .filter { $0.hasPrefix("ui-runner-") && $0.hasSuffix(".json") }.sorted().map { stateDirectory + "/" + $0 }
    }
}

extension GlobalPaths {
    /// Where the runner of the clone `udid` writes its port once it is listening. It is under the cache, where a
    /// simulator process can always write, and named by udid, which is unique across worktrees.
    public func runnerReadyFile(udid: String) -> String { cacheDirectory + "/ui-runner/ready/\(udid).json" }
}

public enum Runners {
    /// The argument that identifies the runner's xcodebuild, so a reused pid is never taken for it.
    public static let marker = "test-without-building"
    /// SIGTERM ends xcodebuild in under a second; after this long it is killed.
    public static let stopTimeout: Duration = .seconds(10)

    public static func load(_ file: String) -> RunnerRecord? {
        guard let data = FileManager.default.contents(atPath: file) else { return nil }
        return try? JSONCoding.decoder.decode(RunnerRecord.self, from: data)
    }

    /// Writes the record for its owner only: it holds the token that lets a local process drive the simulator.
    public static func save(_ record: RunnerRecord, to file: String) throws {
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try JSONCoding.encoder(pretty: true).encode(record).write(to: URL(fileURLWithPath: file), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
    }

    /// Stops the runner with SIGTERM (never SIGINT: xcodebuild lingers for minutes), then removes its record and ready
    /// file, but only while the record on disk still names this process: a newer runner's files are left alone.
    @discardableResult
    public static func stop(_ record: RunnerRecord, file: String, detached: any DetachedProcessLaunching) async -> DetachedStop {
        let outcome = await detached.stop(record.process, marker: marker, signal: SIGTERM, timeout: stopTimeout)
        if load(file).map({ $0.process == record.process }) ?? true {
            try? FileManager.default.removeItem(atPath: file)
            try? FileManager.default.removeItem(atPath: record.readyFile)
        }
        return outcome
    }

    /// Stops the runners in `paths`, only `device`'s when given: for `sim shutdown`, `sim erase`, and `wt remove`.
    public static func stopAll(in paths: WorktreePaths, device: String? = nil, detached: any DetachedProcessLaunching) async -> [String] {
        var notes: [String] = []
        for file in paths.runnerFiles {
            guard let record = load(file), device == nil || record.device == device else { continue }
            let outcome = await stop(record, file: file, detached: detached)
            notes.append(outcome == .notRunning ? "removed the stale \(record.device) UI runner record" : "stopped the \(record.device) UI runner")
        }
        return notes
    }

    /// The lock that makes start-or-attach one at a time for a worktree's device.
    public static func lockPath(globalPaths: GlobalPaths, worktreeRoot: String, device: String) -> String {
        let key = String(worktreeRoot.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let name = String(device.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return globalPaths.locksDirectory + "/ui-runner-" + key + "-" + name + ".lock"
    }

    /// UI driving works on iPhone and iPad simulators only.
    public static func requireIOS(_ device: ProvisionedDevice, name: String) throws {
        guard device.runtimeIdentifier.contains("SimRuntime.iOS-") else {
            throw XcdError(.platformUnsupported, "UI driving supports iPhone and iPad simulators; '\(name)' runs \(device.runtime)",
                           next: "use an iPhone or iPad device from .xcdev.yml with `--device <name>`")
        }
    }
}
