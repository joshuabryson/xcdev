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
    }

    /// The check's id, e.g. "orphaned-clones".
    public let check: String
    public let message: String
    public let action: Action?
    /// What `--fix` does, in words.
    public let fix: String?
    /// What to do by hand when there is no fix.
    public let next: String?
    /// What the fix acts on: a simulator's udid, a registry id, or a worktree path.
    public let subject: String?
    public var fixed = false
    public var fixError: String?

    public init(check: String, message: String, action: Action? = nil, fix: String? = nil, next: String? = nil,
                subject: String? = nil) {
        self.check = check
        self.message = message
        self.action = action
        self.fix = fix
        self.next = next
        self.subject = subject
    }
}

/// A doctor check: finds problems and, for those with an action, repairs them.
public protocol DoctorCheck: Sendable {
    var id: String { get }
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
        guard let directory = device.deviceDirectory,
              let created = (try? FileManager.default.attributesOfItem(atPath: directory))?[.creationDate] as? Date else { return nil }
        return now.timeIntervalSince(created)
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
