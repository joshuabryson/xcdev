import Foundation

/// The project's .swiftlint.yml keeps SwiftLint out of the worktree's `.xcdev/` folder (see `SwiftLintConfig`).
/// Only for a project that has the file: the fix edits it, and never creates one.
public struct SwiftLintCheck: DoctorCheck {
    public let id = "swiftlint"

    func config(_ env: DoctorEnvironment) -> SwiftLintConfig? {
        env.project.flatMap { SwiftLintConfig.load(in: $0.location.worktreeRoot) }
    }

    public func applies(_ env: DoctorEnvironment) -> Bool { config(env) != nil }

    /// A file laid out in a way the edit doesn't know is reported with what to add by hand.
    public func detect(_ env: DoctorEnvironment) -> [DoctorProblem] {
        guard let config = config(env), config.searchesStateFolder else { return [] }
        guard config.excludingStateFolder != nil else {
            return [DoctorProblem(check: id, message: SwiftLintConfig.problem, next: SwiftLintConfig.byHand)]
        }
        return [DoctorProblem(check: id, message: SwiftLintConfig.problem, action: .excludeFromSwiftLint,
                              fix: "add `\(SwiftLintConfig.stateFolder)` to its `excluded` list", subject: config.path)]
    }

    /// Edits the file as it is now, not as `detect` saw it.
    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) throws {
        guard problem.action == .excludeFromSwiftLint else { return }
        guard let config = config(env), config.searchesStateFolder else {
            throw DoctorLeftAlone(note: "\(SwiftLintConfig.fileName) no longer needs the entry; left alone")
        }
        guard try config.excludeStateFolder() else {
            throw XcdError(.internalError, "\(SwiftLintConfig.fileName) changed into a layout xcd doesn't edit", next: SwiftLintConfig.byHand)
        }
    }
}
