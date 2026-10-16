import Foundation

/// After an xcodebuild run that built the worktree's code: updates the record of warnings, and works out what the
/// result shows.
struct WarningKeeper: Sendable {
    let runner: any ProcessRunning

    static let firstRecord = "xcd keeps warnings from this build on; a file this build did not compile shows none until it is compiled again "
        + "(`xcd build --clean` compiles everything)"
    static let unreadable = "the warnings are not known: xcd could not read this build's result bundle, so the record of earlier builds is left as it was"
    static let unreadableLog = "the warnings are not known: xcd could not read this build's log, so the record of earlier builds is left as it was"

    func keep(_ run: BuildService.ResultBundleRun, of plan: BuildPlan, configuration: String?, in ctx: WorktreeContext) async -> KnownWarnings {
        guard let results = run.buildResults else { return KnownWarnings(notes: run.resultBundle == nil ? [] : [Self.unreadable]) }
        guard let logged = Self.compiledFiles(in: run.log) else { return KnownWarnings(notes: [Self.unreadableLog]) }
        let sight = WarningSight(warnings: results.warnings, count: results.warningCount, compiled: Set(logged.compactMap(Disk.realPath)))
        let file = WarningRecord.file(scheme: plan.scheme, device: plan.target.name, configuration: configuration, in: ctx.paths)
        var notes: [String] = []
        let record: WarningRecord
        do {
            let updated = try await WarningRecord.update(at: file) { $0.updated(compiled: logged, warnings: results.warnings) }
            record = updated.record
            if updated.isNew { notes.append(Self.firstRecord) }
        } catch {
            record = (WarningRecord.load(file) ?? WarningRecord()).updated(compiled: logged, warnings: results.warnings)
            notes.append("xcd could not keep this build's warnings: \(Self.sentence(error))")
        }
        var known = KnownWarnings.of(sight, record: record, touched: nil)
        if known.count > 0 || record.files.keys.contains(where: { !record.isCurrent($0) }) {
            do {
                known = KnownWarnings.of(sight, record: record, touched: try await touched(in: ctx))
            } catch {
                notes.append("the warnings of the files you changed are not listed: \(Self.sentence(error))")
            }
        }
        known.notes = notes
        return known
    }

    /// The kept files the log names, or nil when the log cannot be read. A byte that is not valid UTF-8, such as one in
    /// a run script's output, costs only the line it is on.
    static func compiledFiles(in log: String) -> Set<String>? {
        (try? Data(contentsOf: URL(fileURLWithPath: log))).map { CompiledFiles.parse(String(decoding: $0, as: UTF8.self)) }
    }

    static func sentence(_ error: any Error) -> String { (error as? XcdError)?.message ?? error.localizedDescription }

    /// The files the change touched, measured from the worktree's base, by their paths with
    /// links resolved, each mapped to its path in the worktree.
    func touched(in ctx: WorktreeContext) async throws -> [String: String] {
        let root = ctx.location.worktreeRoot
        let base = try await BaseResolver(runner: runner).resolve(in: root, flag: nil, recorded: ctx.state.base)
        let files = try await ChangeFinder(runner: runner).touched(in: root, since: base.forkPoint)
        return Dictionary(files.compactMap { path in Disk.realPath(root + "/" + path).map { ($0, path) } }, uniquingKeysWith: { first, _ in first })
    }
}
