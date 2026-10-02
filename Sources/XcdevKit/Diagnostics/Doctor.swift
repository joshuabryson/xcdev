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
    func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws
}

extension DoctorCheck {
    public func applies(_ env: DoctorEnvironment) -> Bool { true }
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

    /// Removes a clone from the worktree state that records it, so it is cloned again on next use.
    func forget(udid: String) throws {
        for var state in states.values {
            guard let name = state.devices.first(where: { $0.value.udid == udid })?.key else { continue }
            state.devices[name] = nil
            try WorktreeStateStore.save(state, WorktreePaths(root: state.path))
        }
    }
}
