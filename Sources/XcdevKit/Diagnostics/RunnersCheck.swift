import Foundation

/// UI runners xcd started: records whose xcodebuild is gone, and runners whose xcodebuild is alive but
/// which no longer answer (xcodebuild can outlive its runner by minutes). A runner being started by another xcd
/// holds its lock and is left alone.
public struct StaleUIRunnersCheck: DoctorCheck {
    public let id = "ui-runners"
    public init() { /* stateless */ }

    struct Found {
        let entry: RegistryEntry
        let file: String
        let record: RunnerRecord
    }

    func found(_ env: DoctorEnvironment) -> [Found] {
        env.registry.filter { env.states[$0.id] != nil }.flatMap { entry in
            WorktreePaths(root: entry.path).runnerFiles.compactMap { file in
                Runners.load(file).map { Found(entry: entry, file: file, record: $0) }
            }
        }
    }

    func starting(_ item: Found, _ env: DoctorEnvironment) -> Bool {
        FileLock.isHeld(at: Runners.lockPath(globalPaths: env.globalPaths, worktreeRoot: item.entry.path, device: item.record.device))
    }

    func answers(_ record: RunnerRecord, _ env: DoctorEnvironment) async -> Bool {
        guard let port = record.port else { return false }
        return await env.runnerClient.health(port: port, token: record.token) != nil
    }

    public func detect(_ env: DoctorEnvironment) async -> [DoctorProblem] {
        var problems: [DoctorProblem] = []
        for item in found(env) where !starting(item, env) {
            let owner = "\(item.entry.project)/\(item.entry.name)"
            if !env.detached.inspector.isRunning(item.record.process, marker: Runners.marker) {
                problems.append(DoctorProblem(check: id, message: "\(owner) has a record of a \(item.record.device) UI runner that already ended",
                                              action: .forgetRunner, fix: "delete the record", subject: item.file))
            } else if !(await answers(item.record, env)) {
                problems.append(DoctorProblem(check: id, message: "\(owner)'s \(item.record.device) UI runner is running but not answering",
                                              action: .stopRunner, fix: "stop it; the next `xcd ui` command starts a new one",
                                              subject: item.file))
            }
        }
        return problems
    }

    public func inProgress(_ env: DoctorEnvironment) -> [String] {
        found(env).filter { starting($0, env) }.map {
            "\($0.entry.project)/\($0.entry.name)'s \($0.record.device) UI runner is being started by another xcd; left alone"
        }
    }

    /// Takes the runner's lock without waiting (a runner being started holds it), then looks again before acting:
    /// the record is re-read, and a runner that came back is left alone. The lock is held through the health probe
    /// and the stop, so no `xcd ui` can start a new runner in between and have it stopped or its record deleted.
    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws {
        guard let file = problem.subject, let item = found(env).first(where: { $0.file == file }) else { return }
        let lock = Runners.lockPath(globalPaths: env.globalPaths, worktreeRoot: item.entry.path, device: item.record.device)
        let acted: Void? = try await FileLock.withLockIfFree(at: lock) {
            try await act(on: problem, file: file, entry: item.entry, env)
        }
        if acted == nil {
            throw DoctorLeftAlone(note: "the \(item.record.device) UI runner is being started by another xcd; left alone")
        }
    }

    /// The fix itself, with the runner's lock held. Everything is re-read here, not taken from before the lock.
    private func act(on problem: DoctorProblem, file: String, entry: RegistryEntry, _ env: DoctorEnvironment) async throws {
        guard let record = Runners.load(file) else { return }
        let running = env.detached.inspector.isRunning(record.process, marker: Runners.marker)
        switch problem.action {
        case .forgetRunner?:
            guard !running else { throw DoctorLeftAlone(note: "the \(record.device) UI runner in \(file) is running again; left alone") }
            try FileManager.default.removeItem(atPath: file)
            try? FileManager.default.removeItem(atPath: record.readyFile)
        case .stopRunner?:
            guard running, !(await answers(record, env)) else {
                throw DoctorLeftAlone(note: "the \(record.device) UI runner in \(file) changed since doctor looked; left alone")
            }
            await Runners.stop(record, file: file, detached: env.detached)
        default:
            return
        }
    }
}
