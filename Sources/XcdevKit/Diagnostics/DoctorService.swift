import Foundation

/// Space used by xcd: each worktree's `.xcdev/` folder (from du) and the simulators (from simctl).
public struct DiskSummary: Codable, Sendable, Equatable {
    public struct Worktree: Codable, Sendable, Equatable {
        public let project: String
        public let name: String
        public let bytes: Int64
    }

    /// Largest first.
    public let worktrees: [Worktree]
    public let clonesBytes: Int64
    public let templatesBytes: Int64

    public var text: String {
        let total = worktrees.reduce(0) { $0 + $1.bytes }
        let largest = worktrees.prefix(5).map { "\($0.project)/\($0.name) \(ByteText.format($0.bytes))" }
        return "disk: worktrees \(ByteText.format(total))" + (largest.isEmpty ? "" : " (" + largest.joined(separator: ", ") + ")")
            + ", clones \(ByteText.format(clonesBytes)), templates \(ByteText.format(templatesBytes))"
            + "  (APFS clones are counted in full)"
    }
}

/// `xcd doctor` and `xcd prune`.
public struct DoctorReport: Reportable {
    public struct CheckResult: Codable, Sendable, Equatable {
        public let id: String
        public let problems: [DoctorProblem]
    }

    public let fixMode: Bool
    public let checks: [CheckResult]
    public let disk: DiskSummary?

    public var problems: [DoctorProblem] { checks.flatMap(\.problems) }
    /// Problems that are still there.
    public var remaining: [DoctorProblem] { problems.filter { !$0.fixed } }

    public var text: String {
        let fixed = problems.count - remaining.count
        var lines = ["doctor: \(problems.count) problem\(problems.count == 1 ? "" : "s")" + (fixMode ? ", \(fixed) fixed" : "")]
        for check in checks {
            if check.problems.isEmpty { lines.append("ok       \(check.id)") }
            for problem in check.problems {
                var line: String
                if problem.fixed {
                    line = "fixed    \(check.id)  \(problem.message)"
                } else if let error = problem.fixError {
                    line = "failed   \(check.id)  \(problem.message)  (fix failed: \(error))"
                } else {
                    line = "problem  \(check.id)  \(problem.message)"
                    if let fix = problem.fix, !fixMode { line += "  (--fix: \(fix))" }
                    if let next = problem.next { line += "  next: \(next)" }
                }
                lines.append(line)
            }
        }
        if let disk { lines.append(disk.text) }
        return lines.joined(separator: "\n")
    }

    public var failure: XcdError? {
        guard !remaining.isEmpty else { return nil }
        let fixable = remaining.filter { $0.action != nil && $0.fixError == nil }
        let next: String
        if !fixMode, !fixable.isEmpty {
            next = "run `xcd doctor --fix` to fix \(fixable.count) of them" + (fixable.count < remaining.count ? "; the others say what to do" : "")
        } else {
            next = remaining.first { $0.next != nil }?.next ?? "read the problems above; `xcd doctor` checks again"
        }
        return XcdError(.doctorProblems, "\(remaining.count) problem\(remaining.count == 1 ? "" : "s") remain", next: next)
    }
}

/// Runs doctor checks. Without `fix`, nothing is changed.
public struct DoctorService: Sendable {
    public let runner: any ProcessRunning
    public let globalPaths: GlobalPaths
    public let discovery: XcodeDiscovery
    public let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void

    public init(runner: any ProcessRunning, globalPaths: GlobalPaths, discovery: XcodeDiscovery? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.runner = runner
        self.globalPaths = globalPaths
        self.discovery = discovery ?? XcodeDiscovery(runner: runner)
        self.now = now
        self.sleep = sleep
    }

    /// Every check, in the order fixes should happen: worktrees before the clones they leave behind.
    public static var allChecks: [any DoctorCheck] {
        [CoreSimulatorCheck(), TemplatesCheck()]
    }

    /// `directory` is where doctor was run; inside a project, its setup is checked too.
    public func run(fix: Bool, checks: [any DoctorCheck] = allChecks, from directory: String?,
                    includeDisk: Bool = true) async -> DoctorReport {
        var env = await environment(from: directory)
        var results: [DoctorReport.CheckResult] = []
        for check in checks where check.applies(env) {
            var problems = await check.detect(env)
            if fix, problems.contains(where: { $0.action != nil }) {
                for index in problems.indices where problems[index].action != nil {
                    do {
                        try await check.fix(problems[index], env)
                        problems[index].fixed = true
                    } catch let error as XcdError {
                        problems[index].fixError = error.message + (error.next.map { "; \($0)" } ?? "")
                    } catch {
                        problems[index].fixError = "\(error)"
                    }
                }
                env = await environment(from: directory)
            }
            results.append(.init(id: check.id, problems: problems))
        }
        return DoctorReport(fixMode: fix, checks: results, disk: includeDisk ? await disk(env) : nil)
    }

    public func environment(from directory: String?) async -> DoctorEnvironment {
        var catalog: SimCatalog?
        var catalogFailure: XcdError?
        do {
            catalog = try await CoreSimulatorCheck.listCatalog(SimctlClient(runner: runner, developerDir: nil, sleep: sleep))
        } catch let error as XcdError {
            catalogFailure = error
        } catch {
            catalogFailure = XcdError(.simulatorFailed, "\(error)")
        }
        var registry: [RegistryEntry] = []
        var registryError: XcdError?
        do {
            registry = try Registry(paths: globalPaths).entries()
        } catch let error as XcdError {
            registryError = error
        } catch {}
        var states: [String: WorktreeState] = [:]
        for entry in registry where FileManager.default.fileExists(atPath: entry.path) {
            if let state = try? WorktreeStateStore.load(WorktreePaths(root: entry.path)) { states[entry.id] = state }
        }
        return DoctorEnvironment(runner: runner, globalPaths: globalPaths, catalog: catalog, catalogFailure: catalogFailure,
                                 registry: registry, registryError: registryError, states: states,
                                 project: await project(from: directory), discovery: discovery, now: now(), sleep: sleep)
    }

    /// The project at `directory`, read-only: a missing or invalid .xcdev.yml is recorded, not thrown.
    func project(from directory: String?) async -> DoctorProject? {
        guard let directory, let location = try? await WorktreeLocator(runner: runner).locate(from: directory) else { return nil }
        let paths = WorktreePaths(root: location.worktreeRoot)
        do {
            let config = try ConfigLoader.load(worktreeRoot: location.worktreeRoot, projectRoot: location.projectRoot)
            return DoctorProject(location: location, config: config, configError: nil, state: try? WorktreeStateStore.load(paths))
        } catch let error as XcdError where error.code == .configMissing {
            return nil
        } catch let error as XcdError {
            return DoctorProject(location: location, config: nil, configError: error, state: nil)
        } catch {
            return nil
        }
    }

    func disk(_ env: DoctorEnvironment) async -> DiskSummary {
        let existing = env.registry.filter { env.states[$0.id] != nil }
        let sizes = await DiskUsage(runner: runner).bytes(of: existing.map { WorktreePaths(root: $0.path).stateDirectory })
        let worktrees = existing.compactMap { entry in
            sizes[WorktreePaths(root: entry.path).stateDirectory].map { DiskSummary.Worktree(project: entry.project, name: entry.name, bytes: $0) }
        }.sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
        let devices = env.catalog?.devices ?? []
        func total(_ prefix: String) -> Int64 {
            devices.filter { $0.name.hasPrefix(prefix) }.reduce(0) { $0 + ($1.dataPathSize ?? 0) }
        }
        return DiskSummary(worktrees: worktrees, clonesBytes: total(SimNaming.clonePrefix), templatesBytes: total(SimNaming.templatePrefix))
    }
}
