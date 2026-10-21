import Foundation

/// One thing `xcd doctor` found.
public struct DoctorProblem: Codable, Sendable, Equatable {
    /// What `--fix` does about it, machine-readable. Nil when a person has to act (`next` says how).
    public enum Action: String, Codable, Sendable {
        case restartCoreSimulator = "restart_coresimulator"
        case dropRegistryEntry = "drop_registry_entry"
        case discardWorktree = "discard_worktree"
        case deleteSimulator = "delete_simulator"
        case shutDownSimulator = "shut_down_simulator"
        case unpinXcode = "unpin_xcode"
        case deleteScratch = "delete_scratch"
        case deletePackageCache = "delete_package_cache"
        case stopRecording = "stop_recording"
        case forgetRecording = "forget_recording"
        case stopRunner = "stop_ui_runner"
        case forgetRunner = "forget_ui_runner"
        case excludeFromSwiftLint = "exclude_from_swiftlint"
        case addLintSection = "add_lint_section"
        case addFormatSection = "add_format_section"
        case rewriteAgentBlock = "rewrite_agent_block"
    }

    /// Whose problem it is, which decides where `--fix` may repair it.
    public enum Scope: String, Codable, Sendable {
        /// The project doctor runs in.
        case project
        case otherProject = "other-project"
        /// A project none of whose checkouts is there any more.
        case goneProject = "gone-project"
        /// What xcd keeps for every project on this Mac.
        case xcd
        /// The CoreSimulator service.
        case mac
    }

    /// The check's id, e.g. "orphaned-clones".
    public let check: String
    public let message: String
    public let action: Action?
    /// What `--fix` does, in words.
    public let fix: String?
    /// What to do by hand when there is no fix, or, for another project's problem, where to fix it.
    public var next: String?
    /// What the fix acts on: a simulator's udid, a registry id, a worktree path, the cache directory, or a package cache.
    public let subject: String?
    /// What the fix did, in words, for the line of a fixed problem.
    public let done: String?
    public var fixed = false
    public var fixError: String?
    /// Set by doctor from the check's reach and `projectRoot`.
    public var scope: Scope? {
        didSet { elsewhere = scope == .otherProject ? true : nil }
    }
    /// True for another project's problem, which doctor lists apart and which never fails its run. Follows `scope`.
    public private(set) var elsewhere: Bool?
    /// The main checkout of the project the problem is in, when it is a project's.
    public var projectRoot: String?

    public init(check: String, message: String, action: Action? = nil, fix: String? = nil, next: String? = nil,
                subject: String? = nil, done: String? = nil, projectRoot: String? = nil) {
        self.check = check
        self.message = message
        self.action = action
        self.fix = fix
        self.next = next
        self.subject = subject
        self.done = done
        self.projectRoot = projectRoot
    }
}

/// A doctor check: finds problems and, for those with an action, repairs them.
public protocol DoctorCheck: Sendable {
    var id: String { get }
    /// What the check's problems are about, which decides whose they are. Every check's is in `DoctorScopes.swift`.
    var reach: DoctorReach { get }
    /// False when the check has nothing to look at (the project check outside a project), so it isn't listed.
    func applies(_ env: DoctorEnvironment) -> Bool
    func detect(_ env: DoctorEnvironment) async -> [DoctorProblem]
    /// What the check left alone because another xcd is working on it right now. Reported, but not problems.
    func inProgress(_ env: DoctorEnvironment) -> [String]
    /// Repairs `problem`. Throws `DoctorLeftAlone` when, on a closer look, it turns out to be another xcd's work
    /// in progress or no longer a problem.
    func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws
}

extension DoctorCheck {
    public func applies(_ env: DoctorEnvironment) -> Bool { true }
    public func inProgress(_ env: DoctorEnvironment) -> [String] { [] }
}

/// Thrown by a fix that found, once it held the locks or looked again, that it must not act: another xcd is
/// creating or removing the worktree, or a clone left its stuck state by itself. The problem is then reported
/// with `note` as in progress, not as fixed or failed.
public struct DoctorLeftAlone: Error, Sendable, Equatable {
    public let note: String
    public init(note: String) { self.note = note }
}

/// The project doctor was run in, read without writing anything.
public struct DoctorProject: Sendable {
    public let location: ProjectLocation
    public let config: XcdevConfig?
    public let configError: XcdError?
    public let state: WorktreeState?
    /// The main checkout's `.xcdev.yml`, when `config` is borrowed from it.
    public var borrowedConfig: String?
}

/// A snapshot of everything the checks look at, taken once and again after each round of fixes.
public struct DoctorEnvironment: Sendable {
    public let runner: any ProcessRunning
    public let globalPaths: GlobalPaths
    public let catalog: SimCatalog?
    /// Why `simctl list` failed (after retries), when `catalog` is nil.
    public let catalogFailure: XcdError?
    public let registry: [RegistryEntry]
    public let registryError: XcdError?
    /// Registry id → that worktree's state, for checkouts that still exist.
    public let states: [String: WorktreeState]
    public let project: DoctorProject?
    /// The project git found doctor in, with or without an `.xcdev.yml`: whose problems are "this project's".
    public var location: ProjectLocation?
    /// Why git could not say which project doctor runs in, when it failed.
    public var projectFailure: XcdError?
    public let discovery: XcodeDiscovery
    public let now: Date
    public let sleep: @Sendable (Duration) async throws -> Void
    /// Registry ids of worktrees whose lock a `wt create` or `wt remove` holds, probed once for this snapshot so
    /// every check sees the same answer (an entry is never both a problem and in progress).
    public var busy: Set<String> = []
    /// Registry entries an earlier snapshot of this same doctor run had and this one doesn't, typically because
    /// a fix dropped them. Their clones still have a known owner (a gone worktree), so they can be deleted in
    /// the same run even when the dropped entry was its project's last one.
    public var formerEntries: [RegistryEntry] = []
    /// Whether this is a `--fix` run. A plain `doctor` reports a clone that is still booting as in progress, since
    /// only the fix waits to see whether it settles.
    public var fixing = false
    /// How recorded processes are inspected and stopped.
    public var detached: any DetachedProcessLaunching = SystemDetachedProcesses()
    /// How a UI runner is asked whether it still answers.
    public var runnerClient: RunnerClient = RunnerClient(transport: URLSessionRunnerTransport())
    /// What answers whether the app that runs xcd holds the Mac grants, and which app that is (`mac-permissions`).
    public var accessibility: @Sendable () -> any AccessibilityAPI = { SystemAccessibility() }
    public var hostApp: @Sendable () -> String = { MacHostApp.live() }

    /// Sets how recorded processes and UI runners are inspected, stopped, and asked for health.
    mutating func useProcesses(detached: any DetachedProcessLaunching, runnerClient: RunnerClient) {
        self.detached = detached
        self.runnerClient = runnerClient
    }

    public var simctl: SimctlClient { SimctlClient(runner: runner, developerDir: nil, sleep: sleep) }

    /// Why `simctl list` failed, in one line: the error and its last stderr line. The `command:` and `exit:`
    /// detail lines are left out, since the message already names the command and its exit code.
    public var catalogError: String? {
        guard let failure = catalogFailure else { return nil }
        let reason = failure.details.last.flatMap { $0.hasPrefix("command: ") || $0.hasPrefix("exit: ") ? nil : $0 }
        return ([failure.message] + (reason.map { [$0] } ?? [])).joined(separator: ": ")
    }

    /// Every udid some worktree has recorded as its clone.
    public var recordedClones: Set<String> { Set(states.values.flatMap { $0.devices.values.map(\.udid) }) }

    /// Seconds since `device` was created or cloned (its folder's creation date); nil when unknown.
    public func age(of device: SimDevice) -> TimeInterval? {
        device.created.map { now.timeIntervalSince($0) }
    }

    /// Whether a `wt create` or `wt remove` of this worktree was running when the snapshot was taken.
    func isBusy(_ entry: RegistryEntry) -> Bool { busy.contains(entry.id) }

    static func busyNote(_ entry: RegistryEntry) -> String {
        "\(entry.project)/\(entry.name) is being created or removed by another xcd; left alone"
    }

    /// Removes a clone from the worktree state that records it, so it is cloned again on next use.
    ///
    /// The snapshot only says which worktree to edit: its worktree.json is read again just before the edit, so a
    /// clone another agent recorded since (or one an earlier `forget` removed) is kept as it is on disk.
    func forget(udid: String) throws {
        for snapshot in states.values where snapshot.devices.values.contains(where: { $0.udid == udid }) {
            let paths = WorktreePaths(root: snapshot.path)
            guard var state = try WorktreeStateStore.load(paths) else { continue }
            let names = state.devices.filter { $0.value.udid == udid }.map(\.key)
            guard !names.isEmpty else { continue }
            for name in names { state.devices[name] = nil }
            try WorktreeStateStore.save(state, paths)
        }
    }
}
