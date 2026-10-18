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
    var restartSimulators = false
    /// False when git failed to say which project doctor ran in.
    var located = true

    enum CodingKeys: String, CodingKey { case fixMode, checks, disk }

    public var problems: [DoctorProblem] { checks.flatMap(\.problems) }
    /// This project's problems, a gone project's, xcd's own, and CoreSimulator's: the ones that fail a run.
    public var here: [DoctorProblem] { problems.filter { !isElsewhere($0) } }
    /// Other projects' problems, listed apart. None when git cannot say which project doctor
    /// runs in: it cannot tell another project's from this one's then.
    public var elsewhere: [DoctorProblem] { problems.filter(isElsewhere) }
    /// Problems here that are still there.
    public var remaining: [DoctorProblem] { here.filter { !$0.fixed } }

    func isElsewhere(_ problem: DoctorProblem) -> Bool { located && problem.elsewhere == true }

    public var text: String {
        var lines = [header]
        for check in checks {
            let mine = check.problems.filter { !isElsewhere($0) }
            if mine.isEmpty && check.inProgress.isEmpty { lines.append("ok       \(check.id)") }
            for note in check.inProgress { lines.append("busy     \(check.id)  \(note)") }
            lines += mine.map(line(for:))
        }
        if !elsewhere.isEmpty { lines += ["elsewhere (not this project's to fix; ask the user):"] + elsewhere.map(line(for:)) }
        if let disk { lines.append(disk.text) }
        return lines.joined(separator: "\n")
    }

    /// `doctor: 2 problems, 1 fixed, 1 elsewhere`: the problems here, what a fix run fixed of them, and those elsewhere.
    var header: String {
        let away = elsewhere.isEmpty ? "" : ", \(elsewhere.count) elsewhere"
        if here.isEmpty, !elsewhere.isEmpty { return "doctor: no problems here" + away }
        let fixed = fixMode || restartSimulators ? ", \(here.filter(\.fixed).count) fixed" : ""
        return "doctor: \(here.count) problem\(here.count == 1 ? "" : "s")" + fixed + away
    }

    func line(for problem: DoctorProblem) -> String {
        if problem.fixed { return "fixed    \(problem.check)  \(problem.message)" + (problem.done.map { "  (\($0))" } ?? "") }
        if let error = problem.fixError { return "failed   \(problem.check)  \(problem.message)  (fix failed: \(error))" }
        var line = "problem  \(problem.check)  \(problem.message)"
        if let hint = hint(for: problem) { line += "  (\(hint))" }
        if let next = problem.next { line += "  next: \(next)" }
        return line
    }

    /// What plain `--fix` would repair.
    var plainFix: DoctorFixes { DoctorFixes(fix: true, restartSimulators: false, located: located) }

    /// The flag that would fix a problem no run has tried yet: `--restart-simulators` for CoreSimulator, and before a
    /// `--fix` run, `--fix` for what it reaches. Another project's problem says where instead.
    func hint(for problem: DoctorProblem) -> String? {
        guard let fix = problem.fix, problem.action != nil else { return nil }
        if problem.scope == .mac { return "--restart-simulators: \(fix)" }
        return located && !fixMode && plainFix.repairs(problem) ? "--fix: \(fix)" : nil
    }

    public var failure: XcdError? {
        guard !remaining.isEmpty else { return nil }
        return XcdError(.doctorProblems, "\(remaining.count) problem\(remaining.count == 1 ? "" : "s") remain", next: next)
    }

    /// Plain `--fix` for what it reaches, before a `--fix` run; asking the user before restarting CoreSimulator; or
    /// else the first remaining problem's own `next`. When git could not say which project doctor ran in, git's.
    var next: String {
        let first = remaining.first { $0.next != nil && (located || $0.check == ProjectLocationCheck().id) }?.next
        guard located else { return first ?? "read the problems above; `xcd doctor` checks again" }
        var parts: [String] = []
        let fixable = remaining.filter { plainFix.repairs($0) && $0.fixError == nil }
        if !fixMode, !fixable.isEmpty {
            parts.append("run `xcd doctor --fix` to fix \(fixable.count) of them" + (fixable.count < remaining.count ? "; the others say what to do" : ""))
        }
        if remaining.contains(where: { $0.scope == .mac && $0.action != nil && $0.fixError == nil }) {
            parts.append("ask the user before running `xcd doctor --restart-simulators`: it shuts down every booted simulator on this Mac, other agents' too")
        }
        return parts.isEmpty ? first ?? "read the problems above; `xcd doctor` checks again" : parts.joined(separator: "; ")
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
        [ProjectLocationCheck(), CoreSimulatorCheck(), MissingWorktreesCheck(), IncompleteWorktreesCheck(), OrphanedClonesCheck(),
         StuckClonesCheck(), TemplatesCheck(), RecordingsCheck(), StaleUIRunnersCheck(),
         InitScratchCheck(), PackageCacheCheck(),
         QualitySetupCheck(), QualityToolsCheck(), ProjectCheck(), SwiftLintCheck()]
    }

    /// `xcd prune`: worktrees that are gone, and clones nothing owns, with the same reach as `--fix`.
    public static var pruneChecks: [any DoctorCheck] { [ProjectLocationCheck(), MissingWorktreesCheck(), OrphanedClonesCheck()] }

    /// `directory` is where doctor was run; inside a project, its setup is checked too. `fix` repairs that project's
    /// problems, those of projects that are gone, and xcd's own; `restartSimulators` restarts CoreSimulator when it
    /// is not answering.
    public func run(fix: Bool, restartSimulators: Bool = false, checks: [any DoctorCheck] = allChecks, from directory: String?,
                    includeDisk: Bool = true) async -> DoctorReport {
        var env = await environment(from: directory, fixing: fix)
        let fixes = DoctorFixes(fix: fix, restartSimulators: restartSimulators, located: env.projectFailure == nil)
        var results: [DoctorReport.CheckResult] = []
        for check in checks where check.applies(env) {
            var problems = DoctorScopes(env: env).assign(await check.detect(env), reach: check.reach)
            var inProgress = check.inProgress(env)
            if problems.contains(where: fixes.repairs) {
                let fixed = await applyFixes(of: check, to: problems, fixes, env)
                problems = fixed.problems
                inProgress += fixed.leftAlone
                let before = env
                env = await environment(from: directory, fixing: fix)
                env.formerEntries = Self.formerEntries(before, now: env.registry)
            }
            results.append(.init(id: check.id, problems: problems, inProgress: inProgress))
        }
        return DoctorReport(fixMode: fix, checks: results, disk: includeDisk ? await disk(env) : nil,
                            restartSimulators: restartSimulators, located: fixes.located)
    }

    /// Runs the fix of every problem `fixes` reaches. Returns the problems to list, each fixed or with why its fix
    /// failed, and the notes of the ones a fix found it must leave alone, which are no longer listed as problems.
    func applyFixes(of check: any DoctorCheck, to problems: [DoctorProblem], _ fixes: DoctorFixes,
                    _ env: DoctorEnvironment) async -> (problems: [DoctorProblem], leftAlone: [String]) {
        var listed: [DoctorProblem] = []
        var leftAlone: [String] = []
        for var problem in problems {
            if fixes.repairs(problem) {
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
        let (location, projectFailure) = await locate(directory)
        let project = location.flatMap(read)
        var env = DoctorEnvironment(runner: runner, globalPaths: globalPaths, catalog: catalog, catalogFailure: catalogFailure,
                                 registry: registry, registryError: registryError, states: states,
                                 project: project, projectFailure: projectFailure, discovery: discovery, now: now(), sleep: sleep,
                                 busy: busy, fixing: fixing)
        env.location = location
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

    /// Where `directory` is: the project git finds there, whatever its `.xcdev.yml` says. Outside any project there
    /// is none; when git fails to say which it is, its failure.
    func locate(_ directory: String?) async -> (location: ProjectLocation?, failure: XcdError?) {
        guard let directory else { return (nil, nil) }
        do {
            return (try await WorktreeLocator(runner: runner).locate(from: directory), nil)
        } catch let error as XcdError where error.code == .notInProject {
            return (nil, nil)
        } catch let error as XcdError {
            return (nil, error)
        } catch {
            return (nil, XcdError(.internalError, "\(error)"))
        }
    }

    func read(_ location: ProjectLocation) -> DoctorProject? {
        let paths = WorktreePaths(root: location.worktreeRoot)
        do {
            let loaded = try ConfigLoader.checkout(worktreeRoot: location.worktreeRoot, projectRoot: location.projectRoot)
            if let note = loaded.note { Notes.current?.add(note) }
            return DoctorProject(location: location, config: loaded.config, configError: nil, state: try? WorktreeStateStore.load(paths),
                                 borrowedConfig: loaded.borrowedFrom)
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
