import Darwin
import Foundation

/// A recording in progress, kept in `.xcdev/ui-record-<device>.json` so a later xcd can stop it.
public struct RecordingRecord: Codable, Sendable, Equatable {
    public let device: String
    public let udid: String
    public let path: String
    public let log: String
    public let process: ProcessIdentity
    public let startedAt: Date
    /// The argument that identifies a recorder other than simctl's: `_record-window` for a Mac window. Nil for simctl,
    /// and in records written before there was another.
    public var recorder: String?

    public init(device: String, udid: String, path: String, log: String, process: ProcessIdentity, startedAt: Date,
                recorder: String? = nil) {
        self.device = device
        self.udid = udid
        self.path = path
        self.log = log
        self.process = process
        self.startedAt = startedAt
        self.recorder = recorder
    }

    /// What its process's arguments must contain while the recording runs: ask every liveness question with this.
    public var marker: String { recorder ?? Recordings.marker }
}

extension WorktreePaths {
    public func recordingFile(device: String) -> String { stateDirectory + "/ui-record-\(device).json" }
    public func recordingLog(device: String) -> String { logs + "/ui-record-\(device).log" }

    /// Every recording record in this worktree, sorted.
    public var recordingFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: stateDirectory)) ?? [])
            .filter { $0.hasPrefix("ui-record-") && $0.hasSuffix(".json") }.sorted().map { stateDirectory + "/" + $0 }
    }
}

/// How a recording ended.
public struct RecordingStop: Codable, Sendable, Equatable {
    public let device: String
    public let path: String
    public let seconds: Double
    public let bytes: Int64
    public let outcome: DetachedStop
    /// The record's `recorder`: nil for simctl.
    public var recorder: String?

    public var note: String {
        if outcome == .notRunning { return "the \(device) recording had already ended: \(path)" }
        return "stopped the \(device) recording after \(DurationText.format(.milliseconds(Int64(seconds * 1000)))): \(path)"
            + (outcome == .killed ? " (\(Recordings.name(of: recorder)) was killed, so the video may be incomplete)" : "")
    }
}

public enum Recordings {
    /// The argument that identifies simctl's recorder, so a reused pid is never taken for it.
    public static let marker = "recordVideo"

    /// The recorder as messages name it: `simctl`, or `xcd _record-window` for a Mac window.
    public static func name(of recorder: String?) -> String { recorder.map { "xcd \($0)" } ?? "simctl" }

    public static func load(_ file: String) -> RecordingRecord? {
        guard let data = FileManager.default.contents(atPath: file) else { return nil }
        return try? JSONCoding.decoder.decode(RecordingRecord.self, from: data)
    }

    public static func save(_ record: RecordingRecord, to file: String) throws {
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try JSONCoding.encoder(pretty: true).encode(record).write(to: URL(fileURLWithPath: file), options: .atomic)
    }

    /// Stops `record` with SIGINT so its recorder finishes the file (SIGKILL after `MediaService.stopTimeout`), then deletes
    /// the record file, unless another xcd has saved a different recording's record there meanwhile.
    public static func stop(_ record: RecordingRecord, file: String, detached: any DetachedProcessLaunching,
                            now: Date) async -> RecordingStop {
        let outcome = await detached.stop(record.process, marker: record.marker, signal: SIGINT, timeout: MediaService.stopTimeout)
        // A record that no longer decodes can't be acted on, so it goes too; one naming another process stays.
        if load(file).map({ $0.process == record.process }) ?? true { try? FileManager.default.removeItem(atPath: file) }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: record.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return RecordingStop(device: record.device, path: record.path, seconds: now.timeIntervalSince(record.startedAt).rounded(),
                             bytes: bytes, outcome: outcome, recorder: record.recorder)
    }

    /// Stops the recordings in `paths`, only `device`'s when given: for `sim shutdown`, `sim erase`, and `wt remove`.
    public static func stopAll(in paths: WorktreePaths, device: String? = nil, detached: any DetachedProcessLaunching,
                               now: Date) async -> [RecordingStop] {
        var stops: [RecordingStop] = []
        for file in paths.recordingFiles {
            guard let record = load(file), device == nil || record.device == device else { continue }
            stops.append(await stop(record, file: file, detached: detached, now: now))
        }
        return stops
    }
}
