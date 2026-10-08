import Foundation

/// What the report of a build or a test run says about the worktree's setup when it slows every build.
///
/// One thing so far: a .swiftlint.yml that has SwiftLint search `.xcdev/` (see `SwiftLintConfig`). `xcd init` adds
/// the missing entry and `xcd doctor` reports it, but a project can start using SwiftLint long after either ran,
/// and the build is where the time goes. Reading the config costs one small file per build.
public enum SetupNotes {
    /// The notes for a build in the worktree at `worktreeRoot`. Nothing is changed: the file is the project's.
    public static func build(in worktreeRoot: String) -> [String] {
        guard let lint = SwiftLintConfig.load(in: worktreeRoot), lint.searchesStateFolder else { return [] }
        return [lint.warning(fixedBy: SwiftLintConfig.doctorFix)]
    }
}

extension BuildService {
    /// `build`, with the worktree's setup notes in its report. What `xcd build` and `xcd run` run.
    public func buildNotingSetup(_ options: BuildOptions, in ctx: inout WorktreeContext) async throws -> BuildReport {
        var report = try await build(options, in: &ctx)
        report.notes += SetupNotes.build(in: ctx.location.worktreeRoot)
        return report
    }
}
