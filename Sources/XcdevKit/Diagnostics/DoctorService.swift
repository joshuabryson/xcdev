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
    public var mediaBytes: Int64 = 0

    public var text: String {
        let total = worktrees.reduce(0) { $0 + $1.bytes }
        let largest = worktrees.prefix(5).map { "\($0.project)/\($0.name) \(ByteText.format($0.bytes))" }
        var parts: [String] = ["disk: worktrees \(ByteText.format(total))"]
        if !largest.isEmpty { parts.append(" (\(largest.joined(separator: ", ")))") }
        parts.append(", clones \(ByteText.format(clonesBytes)), templates \(ByteText.format(templatesBytes))")
        if mediaBytes > 0 { parts.append(", media \(ByteText.format(mediaBytes))") }
        parts.append("  (APFS clones are counted in full)")
        return parts.joined()
    }
}

/// `xcd doctor` and `xcd prune`.
public struct DoctorReport: Reportable {
    public struct CheckResult: Codable, Sendable, Equatable {
        public let id: String
        public let problems: [DoctorProblem]
        /// Things another xcd is working on (`DoctorCheck.inProgress`); they don't count as problems.
        public var inProgress: [String] = []
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
            if check.problems.isEmpty && check.inProgress.isEmpty { lines.append("ok       \(check.id)") }
            for note in check.inProgress { lines.append("busy     \(check.id)  \(note)") }
            for problem in check.problems {
                var line: String
                if problem.fixed {
                    line = "fixed    \(check.id)  \(problem.message)"
                    if let done = problem.done { line += "  (\(done))" }
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
    public let detached: any DetachedProcessLaunching
    public let runnerClient: RunnerClient
    let sleep: @Sendable (Duration) async throws -> Void

    public init(runner: any ProcessRunning, globalPaths: GlobalPaths, discovery: XcodeDiscovery? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                detached: any DetachedProcessLaunching = SystemDetachedProcesses(),
                runnerClient: RunnerClient = RunnerClient(transport: URLSessionRunnerTransport()),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.runner = runner
        self.globalPaths = globalPaths
        self.discovery = discovery ?? XcodeDiscovery(runner: runner)
        self.now = now
        self.detached = detached
        self.runnerClient = runnerClient
        self.sleep = sleep
    }

    /// Every check, in the order fixes should happen: worktrees before the clones they leave behind. Scratch
    /// folders and package caches depend on nothing else, so they come after the simulators, before the project's
    /// `lint:` section, its own setup, and its SwiftLint config.
    public static var allChecks: [any DoctorCheck] {
        [CoreSimulatorCheck(), MissingWorktreesCheck(), IncompleteWorktreesCheck(), OrphanedClonesCheck(),
         StuckClonesCheck(), TemplatesCheck(), RecordingsCheck(), StaleUIRunnersCheck(),
         InitScratchCheck(), PackageCacheCheck(),
         QualitySetupCheck(), QualityToolsCheck(), ProjectCheck(), SwiftLintCheck()]
    }

    /// `xcd prune`: worktrees that are gone, and clones nothing owns.
    public static var pruneChecks: [any DoctorCheck] { [MissingWorktreesCheck(), OrphanedClonesCheck()] }

    /// `directory` is where doctor was run; inside a project, its setup is checked too.
    public func run(fix: Bool, checks: [any DoctorCheck] = allChecks, from directory: String?,
                    includeDisk: Bool = true) async -> DoctorReport {
        var env = await environment(from: directory, fixing: fix)
        var results: [DoctorReport.CheckResult] = []
        for check in checks where check.applies(env) {
            var problems = DoctorScopes(env: env).assign(await check.detect(env), reach: check.reach)
            var inProgress = check.inProgress(env)
            if fix, problems.contains(where: { $0.action != nil }) {
                let fixed = await applyFixes(of: check, to: problems, env)
                problems = fixed.problems
                inProgress += fixed.leftAlone
                let before = env
                env = await environment(from: directory, fixing: fix)
                env.formerEntries = Self.formerEntries(before, now: env.registry)
            }
            results.append(.init(id: check.id, problems: problems, inProgress: inProgress))
        }
        return DoctorReport(fixMode: fix, checks: results, disk: includeDisk ? await disk(env) : nil)
    }

    /// Runs the fix of every problem that has one. Returns the problems to list, each fixed or with why its fix
    /// failed, and the notes of the ones a fix found it must leave alone, which are no longer listed as problems.
    func applyFixes(of check: any DoctorCheck, to problems: [DoctorProblem],
                    _ env: DoctorEnvironment) async -> (problems: [DoctorProblem], leftAlone: [String]) {
        var listed: [DoctorProblem] = []
        var leftAlone: [String] = []
        for var problem in problems {
            if problem.action != nil {
                do {
                    try await check.fix(problem, env)
                    problem.fixed = true
                } catch let left as DoctorLeftAlone {
                    leftAlone.append(left.note)
                    continue
                } catch let error as XcdError {
                    problem.fixError = error.message + (error.next.map { "; \($0)" } ?? "")
                } catch {
                    problem.fixError = "\(error)"
                }
            }
            listed.append(problem)
        }
        return (listed, leftAlone)
    }

    /// The entries `before` (or a snapshot before it) had that `now` lacks, each once.
    static func formerEntries(_ before: DoctorEnvironment, now: [RegistryEntry]) -> [RegistryEntry] {
        var seen = Set(now.map(\.id))
        return (before.formerEntries + before.registry).filter { seen.insert($0.id).inserted }
    }

    public func environment(from directory: String?, fixing: Bool = false) async -> DoctorEnvironment {
        let (catalog, catalogFailure) = await listCatalog()
        let (registry, registryError) = listRegistry()
        var states: [String: WorktreeState] = [:]
        for entry in registry where FileManager.default.fileExists(atPath: entry.path) {
            if let state = try? WorktreeStateStore.load(WorktreePaths(root: entry.path)) { states[entry.id] = state }
        }
        // Probed once here, never again by the checks: see `DoctorEnvironment.busy`.
        let worktrees = WorktreeService(runner: runner, globalPaths: globalPaths)
        let busy = Set(registry.filter {
            FileLock.isHeld(at: worktrees.lockPath(projectRoot: $0.projectRoot, worktree: $0.name))
        }.map(\.id))
        var env = DoctorEnvironment(runner: runner, globalPaths: globalPaths, catalog: catalog, catalogFailure: catalogFailure,
                                 registry: registry, registryError: registryError, states: states,
                                 project: await project(from: directory), discovery: discovery, now: now(), sleep: sleep,
                                 busy: busy, fixing: fixing)
        env.useProcesses(detached: detached, runnerClient: runnerClient)
        return env
    }

    /// The simulators, or why `simctl list` failed after its retries.
    func listCatalog() async -> (SimCatalog?, XcdError?) {
        do {
            return (try await CoreSimulatorCheck.listCatalog(SimctlClient(runner: runner, developerDir: nil, sleep: sleep)), nil)
        } catch let error as XcdError {
            return (nil, error)
        } catch {
            return (nil, XcdError(.simulatorFailed, "\(error)"))
        }
    }

    /// The registry's entries, or why it could not be read. Any other failure reads as an empty registry.
    func listRegistry() -> ([RegistryEntry], XcdError?) {
        do {
            return (try Registry(paths: globalPaths).entries(), nil)
        } catch let error as XcdError {
            return ([], error)
        } catch {
            return ([], nil)
        }
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
        let projectRoots = Set(env.registry.map(\.projectRoot)).sorted()
        let mediaRoots = projectRoots.compactMap { root -> String? in
            let template = (try? ConfigLoader.load(worktreeRoot: root, projectRoot: root))?.mediaDirTemplate ?? XcdevConfig.defaultMediaDir
            return MediaFolder.root(template: template, projectRoot: root)
        }
        let measured = MediaFolder.measurableRoots(mediaRoots, projectRoots: projectRoots)
        let mediaBytes = await DiskUsage(runner: runner).bytes(of: measured).values.reduce(0, +)
        return DiskSummary(worktrees: worktrees, clonesBytes: total(SimNaming.clonePrefix), templatesBytes: total(SimNaming.templatePrefix),
                           mediaBytes: mediaBytes)
    }
}
