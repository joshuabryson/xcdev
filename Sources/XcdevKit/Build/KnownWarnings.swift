import Foundation

/// What one xcodebuild run saw of warnings: the ones it reported, how many, and the files its log says it compiled,
/// by their paths with links resolved.
struct WarningSight: Sendable {
    let warnings: [Diagnostic]
    let count: Int
    let compiled: Set<String>
}

/// The warnings a build, run, or test result shows.
public struct KnownWarnings: Sendable, Equatable {
    /// Every warning xcd knows: this build's, and the record's of files this build did not compile.
    public var count = 0
    /// The warnings in the files the change touched, this build's first. Nil when those files are not known.
    public var changed: [Diagnostic]?
    /// Touched files whose warnings are not known: they changed since their warnings were recorded, and this build
    /// did not compile them. Relative to the worktree.
    public var unknown: [String] = []
    /// Every warning xcd knows, this build's first.
    public var all: [Diagnostic] = []
    /// What the result says about the record, or about the files the change touched.
    public var notes: [String] = []

    /// What a result shows after a build that saw `sight` and left `record`. `touched` maps the files the change
    /// touched, by their paths with links resolved, to their paths in the worktree; nil when they are not known.
    static func of(_ sight: WarningSight, record: WarningRecord, touched: [String: String]?) -> KnownWarnings {
        let earlier = earlierWarnings(sight, record: record)
        var known = KnownWarnings(count: sight.count + earlier.count, all: sight.warnings + earlier)
        guard let touched else { return known }
        let mine = sight.warnings.filter { $0.file.flatMap(Disk.realPath).map { touched[$0] != nil } == true }
        known.changed = mine + earlier.filter { touched[$0.file ?? ""] != nil }
        known.unknown = touched.filter { path, _ in
            record.files[path] != nil && !record.isCurrent(path) && !sight.compiled.contains(path)
        }.map(\.value).sorted()
        return known
    }

    /// The record's warnings of the files this build did not compile, each while its file is as it was when they were
    /// recorded, and not already among this build's.
    static func earlierWarnings(_ sight: WarningSight, record: WarningRecord) -> [Diagnostic] {
        let mine = WarningRecord.byFile(sight.warnings)
        return record.files.keys.sorted().filter { !sight.compiled.contains($0) && record.isCurrent($0) }.flatMap { path in
            (record.files[path]?.warnings ?? []).filter { !(mine[path] ?? []).contains($0) }.map { warning in
                var diagnostic = Diagnostic(.warning, warning.message, file: path, line: warning.line, column: warning.column)
                diagnostic.earlier = true
                return diagnostic
            }
        }
    }

    /// The warnings a result lists after its errors: every warning with `--warnings`, else those in the files the
    /// change touched. In each list the earlier ones come after `from earlier builds:`.
    func listing(all listAll: Bool) -> [String] {
        let shown = listAll ? all : changed ?? []
        let earlier = shown.filter { $0.earlier == true }.map(\.text)
        return shown.filter { $0.earlier != true }.map(\.text) + (earlier.isEmpty ? [] : ["from earlier builds:"] + earlier)
    }

    /// "2 warnings in the files you changed (1 from an earlier build), 41 in other files (xcd build --warnings)", after
    /// the errors' count of a build that failed. `more` is the command that lists the rest; nil when there is nothing.
    func countLine(errors: Int?, more: String, listedAll: Bool = false) -> String? {
        guard count > 0 || errors != nil else { return nil }
        let prefix = errors.map { Self.plural($0, "error") + ", " } ?? ""
        let hint = listedAll ? "" : " (\(more))"
        guard count > 0 else { return prefix + "0 warnings" }
        guard let changed else { return prefix + Self.plural(count, "warning") + hint }
        let other = count - changed.count
        let earlier = changed.filter { $0.earlier == true }.count
        var parts: [String] = []
        if !changed.isEmpty {
            parts.append(Self.plural(changed.count, "warning") + " in the files you changed" + (earlier > 0 ? " (\(earlier) from an earlier build)" : ""))
        }
        if other > 0 { parts.append((changed.isEmpty ? Self.plural(other, "warning") : "\(other)") + " in other files" + hint) }
        return prefix + parts.joined(separator: ", ")
    }

    /// The line that names the touched files whose warnings are not known.
    var unknownLine: String? {
        guard !unknown.isEmpty else { return nil }
        let files = unknown.count == 1 ? "1 changed file" : "\(unknown.count) changed files"
        return "warnings not known for \(files), which this build did not compile: " + unknown.joined(separator: ", ")
    }

    static func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
}

extension WarningRecord {
    /// Whether the file at `path` is as it was when its warnings were recorded.
    func isCurrent(_ path: String) -> Bool {
        files[path].map { $0.stamp == FileStamp.of(path) } ?? false
    }
}
