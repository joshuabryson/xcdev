import Foundation

/// xcd-named clones that no worktree records.
///
/// Only a clone of a project this registry knows is deleted by `--fix`. Another xcd state folder (a different
/// `XCDEV_HOME`, or a fresh one with no registry.json yet) has its own registry and clones, which this one can't
/// tell apart from orphans, so a clone of an unknown project is reported with the command to delete it by hand,
/// and never fixed. Entries an earlier fix in this run dropped (`formerEntries`) still count as known. Clone names
/// carry only the project's folder name, so a clone of a gone worktree whose project's name several projects in the
/// registry have is never fixed either: xcd cannot tell whose it is.
///
/// A clone is left alone while any registry entry it could belong to says so: that worktree is being created or
/// removed, its checkout can't be reached (`CheckoutPresence`), its worktree.json can't be read, or the clone is
/// younger than `graceSeconds` (or of unknown age), as another agent may be cloning it right now. A clone whose
/// worktree exists is deleted only while it is shut down; a booted one may be in use, so it is only reported.
/// Nothing at all is reported while the registry can't be read. Ownership is decided by name prefix against every
/// entry, since project and device names may contain " · ".
public struct OrphanedClonesCheck: DoctorCheck {
    public let id = "orphaned-clones"
    public let graceSeconds: TimeInterval
    public init(graceSeconds: TimeInterval = 600) { self.graceSeconds = graceSeconds }

    /// Whose a clone is, among the registry entries of its project and worktree name.
    enum Owner {
        /// One of the entries says to leave it alone.
        case leaveAlone
        /// The worktree that exists and does not record it.
        case worktree(RegistryEntry)
        /// Its worktree no longer exists.
        case gone
    }

    public func detect(_ env: DoctorEnvironment) -> [DoctorProblem] {
        guard env.registryError == nil, let catalog = env.catalog else { return [] }
        let recorded = env.recordedClones
        // Entries this run dropped still name their clones' owner: a gone worktree, whose clones can go too.
        let known = env.registry + env.formerEntries
        return catalog.devices.filter { $0.name.hasPrefix(SimNaming.clonePrefix) && !recorded.contains($0.udid) }
            .compactMap { problem(for: $0, known: known, env) }
    }

    func problem(for device: SimDevice, known: [RegistryEntry], _ env: DoctorEnvironment) -> DoctorProblem? {
        let label = "\(device.name) (\(device.udid)) is orphaned"
        let projects = Set(known.filter { device.name.hasPrefix(SimNaming.clonePrefix + $0.project + " · ") }.map(\.projectRoot)).sorted()
        guard let project = projects.first else {
            return DoctorProblem(check: id, message: "\(label): no worktree in this registry is from its project",
                                 next: "it may belong to another xcd state folder (XCDEV_HOME); if not, delete it with `xcrun simctl delete \(device.udid)`",
                                 subject: device.udid)
        }
        let entries = known.filter { device.name.hasPrefix(SimNaming.clone(project: $0.project, worktree: $0.name, device: "")) }
        switch owner(of: device, among: entries, env) {
        case .leaveAlone:
            return nil
        case .worktree(let owner):
            return unrecorded(device, label: label, by: owner)
        case .gone where projects.count > 1:
            return DoctorProblem(check: id, message: "\(label): projects at \(Self.listed(projects)) share its project's name, so xcd cannot tell whose it is",
                                 next: Self.deleteByHand(device), subject: device.udid)
        case .gone:
            return DoctorProblem(check: id, message: "\(label): its worktree no longer exists",
                                 action: .deleteSimulator, fix: "shut it down and delete it", subject: device.udid, projectRoot: project)
        }
    }

    func owner(of device: SimDevice, among entries: [RegistryEntry], _ env: DoctorEnvironment) -> Owner {
        var owner: RegistryEntry?
        for entry in entries {
            if env.isBusy(entry) { return .leaveAlone }
            switch CheckoutPresence.of(entry.path) {
            case .missing: continue
            case .unreachable: return .leaveAlone                              // it may be fine where we can't see
            case .present: break
            }
            guard env.states[entry.id] != nil else { return .leaveAlone }      // its worktree.json is unreadable, or it was dropped
            guard let age = env.age(of: device), age >= graceSeconds else { return .leaveAlone }
            owner = owner ?? entry
        }
        return owner.map { .worktree($0) } ?? .gone
    }

    /// A clone whose worktree exists but does not record it. A booted one may be in use (booted by hand, or by an
    /// agent's own script), so it is only reported.
    func unrecorded(_ device: SimDevice, label: String, by owner: RegistryEntry) -> DoctorProblem {
        let why = "\(owner.project)/\(owner.name) doesn't record it"
        guard device.state == "Shutdown" else {
            return DoctorProblem(check: id, message: "\(label): \(why), and it is \(device.state)", next: Self.deleteByHand(device),
                                 subject: device.udid, projectRoot: owner.projectRoot)
        }
        return DoctorProblem(check: id, message: "\(label): \(why)", action: .deleteSimulator, fix: "delete it", subject: device.udid,
                             projectRoot: owner.projectRoot)
    }

    static func deleteByHand(_ device: SimDevice) -> String {
        "if nothing is using it, delete it with `xcrun simctl shutdown \(device.udid); xcrun simctl delete \(device.udid)`"
    }

    /// "A and B", or "A, B and C".
    static func listed(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Deletes the clone, unless it was booted since `detect` while a worktree it may belong to exists.
    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws {
        guard let udid = problem.subject else { return }
        if let device = try await env.simctl.catalog().device(udid: udid), device.state != "Shutdown",
           env.registry.contains(where: {
               device.name.hasPrefix(SimNaming.clone(project: $0.project, worktree: $0.name, device: ""))
                   && CheckoutPresence.of($0.path) != .missing
           }) {
            throw DoctorLeftAlone(note: "\(device.name) (\(udid)) is now \(device.state); left alone")
        }
        _ = try? await env.simctl.shutdown(udid: udid)
        try await env.simctl.delete(udid: udid)
    }
}
