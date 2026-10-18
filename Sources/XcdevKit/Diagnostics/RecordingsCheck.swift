import Foundation

/// Screen recordings xcd started: records whose process ended without xcd, and recordings that ran past
/// their worktree's `ui.record.maxDuration` with no xcd command since to stop them.
public struct RecordingsCheck: DoctorCheck {
    public let id = "recordings"
    public init() {}

    struct Found {
        let entry: RegistryEntry
        let file: String
        let record: RecordingRecord
    }

    func found(_ env: DoctorEnvironment) -> [Found] {
        env.registry.filter { env.states[$0.id] != nil }.flatMap { entry in
            WorktreePaths(root: entry.path).recordingFiles.compactMap { file in
                Recordings.load(file).map { Found(entry: entry, file: file, record: $0) }
            }
        }
    }

    func limit(_ entry: RegistryEntry) -> Duration {
        (try? ConfigLoader.checkout(worktreeRoot: entry.path, projectRoot: entry.projectRoot))?.config.maxRecording ?? .seconds(600)
    }

    func age(_ found: Found, _ env: DoctorEnvironment) -> Duration {
        .seconds(max(0, env.now.timeIntervalSince(found.record.startedAt)))
    }

    public func detect(_ env: DoctorEnvironment) async -> [DoctorProblem] {
        found(env).compactMap { item in
            let owner = "\(item.entry.project)/\(item.entry.name)"
            guard env.detached.inspector.isRunning(item.record.process, marker: Recordings.marker) else {
                return DoctorProblem(check: id, message: "\(owner) has a record of a \(item.record.device) recording that already ended",
                                     action: .forgetRecording, fix: "delete the record (the video is kept)", subject: item.file,
                                     projectRoot: item.entry.projectRoot)
            }
            guard age(item, env) > limit(item.entry) else { return nil }
            return DoctorProblem(check: id,
                                 message: "\(owner) has been recording \(item.record.device) for \(DurationText.format(age(item, env))), "
                                     + "longer than ui.record.maxDuration (\(DurationText.format(limit(item.entry))))",
                                 action: .stopRecording, fix: "stop it; the video is kept at \(item.record.path)", subject: item.file,
                                 projectRoot: item.entry.projectRoot)
        }
    }

    public func inProgress(_ env: DoctorEnvironment) -> [String] {
        found(env).filter {
            env.detached.inspector.isRunning($0.record.process, marker: Recordings.marker) && age($0, env) <= limit($0.entry)
        }.map { "\($0.entry.project)/\($0.entry.name) is recording \($0.record.device) to \($0.record.path)" }
    }

    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws {
        guard let file = problem.subject, let record = Recordings.load(file) else { return }
        switch problem.action {
        case .forgetRecording?:
            guard !env.detached.inspector.isRunning(record.process, marker: Recordings.marker) else {
                throw DoctorLeftAlone(note: "the \(record.device) recording in \(file) is running again; left alone")
            }
            try FileManager.default.removeItem(atPath: file)
        case .stopRecording?:
            // The record may have been replaced since detect: stop only a recording that is still running and overdue.
            guard let item = found(env).first(where: { $0.file == file }),
                  env.detached.inspector.isRunning(record.process, marker: Recordings.marker),
                  age(Found(entry: item.entry, file: file, record: record), env) > limit(item.entry) else {
                throw DoctorLeftAlone(note: "the \(record.device) recording in \(file) changed since doctor looked; left alone")
            }
            _ = await Recordings.stop(record, file: file, detached: env.detached, now: env.now)
        default:
            return
        }
    }
}
