import Foundation

/// A file's size and modification time, to the nanosecond: what it was when its warnings were recorded.
struct FileStamp: Codable, Sendable, Equatable {
    let size: Int64
    let seconds: Int
    let nanoseconds: Int

    /// Nil when nothing is at `path`.
    static func of(_ path: String) -> FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileStamp(size: Int64(info.st_size), seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }
}

/// One warning as the record keeps it.
struct RecordedWarning: Codable, Sendable, Equatable {
    let line: Int?
    let column: Int?
    let message: String
}

/// The warnings xcd has seen in one source file, and the file as it was when they were recorded.
struct RecordedFile: Codable, Sendable, Equatable {
    var stamp: FileStamp
    var warnings: [RecordedWarning]
}

/// The warnings xcd keeps for one scheme, device, and configuration, because xcodebuild reports a file's warnings
/// only in a build that compiles it. Each file is kept by its path with its links
/// resolved, as the disk spells it, and only the kinds of file whose compiling the log shows (`CompiledFiles.kept`).
struct WarningRecord: Codable, Sendable, Equatable {
    var version = 1
    var files: [String: RecordedFile] = [:]

    /// `.xcdev/warnings/<scheme>~<device>~<configuration>.json`, with `default` for the scheme's own configuration.
    static func file(scheme: String, device: String, configuration: String?, in paths: WorktreePaths) -> String {
        let name = [scheme, device, configuration ?? "default"].joined(separator: "~").replacingOccurrences(of: "/", with: "_")
        return paths.stateDirectory + "/warnings/" + name + ".json"
    }

    /// The record after a build whose results could be read. `compiled` are the files its log names, and `warnings`
    /// what it reported. A compiled file's entry is replaced with its warnings, or with none. A warning in a kept
    /// file that was not compiled, such as one from emitting the module, is added to the file's entry. Entries of
    /// files that are gone, or whose name the disk now spells differently, are dropped.
    func updated(compiled: Set<String>, warnings: [Diagnostic]) -> WarningRecord {
        var record = self
        let found = Self.byFile(warnings)
        let built = Set(compiled.compactMap(Disk.realPath))
        for path in built {
            guard let stamp = FileStamp.of(path) else { continue }
            record.files[path] = RecordedFile(stamp: stamp, warnings: found[path] ?? [])
        }
        for (path, more) in found where !built.contains(path) {
            record.add(more, to: path)
        }
        record.files = record.files.filter { Disk.realPath($0.key) == $0.key }
        return record
    }

    /// Adds warnings to the entry of a file that was not compiled. An entry for the file as it was before it changed
    /// says nothing about it now, and is replaced.
    mutating func add(_ more: [RecordedWarning], to path: String) {
        guard let stamp = FileStamp.of(path) else { return }
        var entry = files[path].flatMap { $0.stamp == stamp ? $0 : nil } ?? RecordedFile(stamp: stamp, warnings: [])
        entry.warnings += more.filter { !entry.warnings.contains($0) }
        files[path] = entry
    }

    /// `warnings` by the path, with links resolved, of each kept file that is there.
    static func byFile(_ warnings: [Diagnostic]) -> [String: [RecordedWarning]] {
        var found: [String: [RecordedWarning]] = [:]
        for warning in warnings {
            guard let file = warning.file, CompiledFiles.isKept(file), let path = Disk.realPath(file) else { continue }
            let recorded = RecordedWarning(line: warning.line, column: warning.column, message: warning.message)
            if found[path]?.contains(recorded) != true { found[path, default: []].append(recorded) }
        }
        return found
    }

    /// The record at `file`, or nil when there is none or it cannot be read: it only holds what builds saw, so one
    /// that cannot be read starts over.
    static func load(_ file: String) -> WarningRecord? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else { return nil }
        return try? JSONCoding.decoder.decode(WarningRecord.self, from: data)
    }

    /// Changes the record at `file` while holding its lock, so that two builds of the worktree at once keep each
    /// other's warnings. Returns the record, and whether there was none before.
    static func update(at file: String, _ change: (WarningRecord) -> WarningRecord) async throws -> (record: WarningRecord, isNew: Bool) {
        try await FileLock.withLock(at: file + ".lock") {
            let before = load(file)
            let record = change(before ?? WarningRecord())
            try JSONCoding.encoder(pretty: false).encode(record).write(to: URL(fileURLWithPath: file), options: .atomic)
            return (record, before == nil)
        }
    }
}
