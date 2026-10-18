import Foundation

/// What a check's problems are about, which decides whose they are.
public enum DoctorReach: Sendable {
    /// Each problem names the project it is in (`DoctorProblem.projectRoot`), from a registry entry.
    case entries
    /// The project doctor runs in, which is all the check looks at.
    case thisProject
    /// What xcd keeps for every project on this Mac: templates, scratch folders, package caches.
    case xcd
    /// The CoreSimulator service.
    case mac
}

extension ProjectLocationCheck { public var reach: DoctorReach { .thisProject } }
extension CoreSimulatorCheck { public var reach: DoctorReach { .mac } }
extension TemplatesCheck { public var reach: DoctorReach { .xcd } }
extension InitScratchCheck { public var reach: DoctorReach { .xcd } }
extension PackageCacheCheck { public var reach: DoctorReach { .xcd } }
extension MissingWorktreesCheck { public var reach: DoctorReach { .entries } }
extension IncompleteWorktreesCheck { public var reach: DoctorReach { .entries } }
extension OrphanedClonesCheck { public var reach: DoctorReach { .entries } }
extension StuckClonesCheck { public var reach: DoctorReach { .entries } }
extension RecordingsCheck { public var reach: DoctorReach { .entries } }
extension StaleUIRunnersCheck { public var reach: DoctorReach { .entries } }
extension QualitySetupCheck { public var reach: DoctorReach { .thisProject } }
extension QualityToolsCheck { public var reach: DoctorReach { .thisProject } }
extension ProjectCheck { public var reach: DoctorReach { .thisProject } }
extension SwiftLintCheck { public var reach: DoctorReach { .thisProject } }
extension AgentDocsCheck { public var reach: DoctorReach { .thisProject } }

/// Works out whose each problem is, from its check's reach and the project it names.
struct DoctorScopes {
    let env: DoctorEnvironment

    func assign(_ problems: [DoctorProblem], reach: DoctorReach) -> [DoctorProblem] {
        problems.map { found in
            var problem = found
            switch reach {
            case .xcd:
                problem.scope = .xcd
            case .mac:
                problem.scope = .mac
            case .thisProject:
                problem.scope = .project
                problem.projectRoot = env.location?.projectRoot
            case .entries:
                problem.scope = problem.scope ?? scope(of: problem.projectRoot)
                problem.next = elsewhere(problem) ?? problem.next
            }
            return problem
        }
    }

    /// Where a problem `--fix` could repair is fixed when it is another project's: from that project's own folder.
    /// A project whose folder cannot be reached, or whose main checkout is gone while another checkout is not, is
    /// left to the user.
    func elsewhere(_ problem: DoctorProblem) -> String? {
        guard problem.action != nil, problem.scope == .otherProject, let root = problem.projectRoot else { return nil }
        switch CheckoutPresence.of(root) {
        case .present:
            return "ask the user before running `xcd doctor --fix` in \(root)"
        case .unreachable:
            return "\(root) can't be reached: it may be on a volume that isn't mounted, or in a folder xcd may not look into; "
                + "ask the user to mount it or fix its permissions, then run `xcd doctor` again"
        case .missing:
            let still = env.registry.first { $0.projectRoot == root && CheckoutPresence.of($0.path) != .missing }?.path ?? root
            return "\((root as NSString).lastPathComponent)'s main checkout is no longer at \(root), but \(still) still is: "
                + "ask the user whether it was moved or deleted"
        }
    }

    /// The scope of a problem in the project whose main checkout is `root`. One whose project nobody knows is
    /// another project's.
    func scope(of root: String?) -> DoctorProblem.Scope {
        guard let root else { return .otherProject }
        if root == env.location?.projectRoot { return .project }
        return isGone(root) ? .goneProject : .otherProject
    }

    /// A project is gone when its main checkout is gone, and so is every other checkout the registry has for it: a
    /// main checkout that was moved leaves its worktrees behind, and someone may be working in them.
    func isGone(_ root: String) -> Bool {
        CheckoutPresence.of(root) == .missing
            && env.registry.filter { $0.projectRoot == root }.allSatisfy { CheckoutPresence.of($0.path) == .missing }
    }
}
