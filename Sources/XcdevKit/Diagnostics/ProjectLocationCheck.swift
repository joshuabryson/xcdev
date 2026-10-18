import Foundation

/// What a doctor run may repair.
public struct DoctorFixes: Sendable, Equatable {
    /// `--fix`: the problems of the project doctor runs in, of projects that are gone, and xcd's own.
    public let fix: Bool
    /// `--restart-simulators`: CoreSimulator, when it is not answering.
    public let restartSimulators: Bool
    /// False when git failed to say which project doctor runs in: then `--fix` repairs nothing, and only
    /// `--restart-simulators` acts, on CoreSimulator, which belongs to no project.
    public let located: Bool

    public init(fix: Bool, restartSimulators: Bool, located: Bool) {
        self.fix = fix
        self.restartSimulators = restartSimulators
        self.located = located
    }

    public func repairs(_ problem: DoctorProblem) -> Bool {
        guard problem.action != nil else { return false }
        switch problem.scope {
        case .project?, .goneProject?, .xcd?: return located && fix
        case .mac?: return restartSimulators
        case .otherProject?, nil: return false
        }
    }
}

/// The project doctor runs in, when git failed to say which it is, as in a worktree whose main checkout was moved
///. It is a problem of the `project` check, and `--fix` then repairs nothing:
/// doctor cannot tell which problems are this project's.
public struct ProjectLocationCheck: DoctorCheck {
    public let id = "project"
    public init() { /* stateless */ }

    public func applies(_ env: DoctorEnvironment) -> Bool { env.projectFailure != nil }

    public func detect(_ env: DoctorEnvironment) -> [DoctorProblem] {
        guard let failure = env.projectFailure else { return [] }
        let next = (failure.next.map { $0 + "; " } ?? "") + "until git can find this project, `xcd doctor --fix` repairs nothing"
        return [DoctorProblem(check: id, message: "\(failure.message) (\(failure.code.rawValue))", next: next)]
    }

    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) {
        // Nothing to repair: git's failure is the user's to fix.
    }
}
