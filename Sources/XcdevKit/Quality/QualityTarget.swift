import Foundation

extension QualityScope {
    /// The scope a command's flags name. `--files` with `--all`, and `--base` with `--all`, are
    /// `usage` errors. `otherwise` says what the command does with neither flag, for the first error's next step.
    static func named(files: Bool, all: Bool, base: String?, otherwise: String) throws -> QualityScope {
        if files && all {
            throw XcdError(.usage, "--files and --all are two scopes", next: "pass one of them, or neither \(otherwise)")
        }
        if all && base != nil {
            throw XcdError(.usage, "--base has no meaning with --all, which compares with nothing", next: "drop one of the two")
        }
        return all ? .all : files ? .files : .lines
    }
}

/// The Swift files one quality command covers, and what they are measured against.
struct QualityTarget: Sendable {
    let scope: QualityScope
    /// Nil with `--all`.
    let base: ResolvedBase?
    let files: [ScopedFile]
    let paths: ScopePaths
}

/// Works out what a quality command covers: `xcd lint` and `xcd format` share it.
struct TargetFinder: Sendable {
    let runner: any ProcessRunning
    /// Where paths on the command line are read from.
    let currentDirectory: String

    /// The files in scope: every Swift file git knows for `--all`, else the ones the working tree changed against
    /// the fork point, in both cases narrowed by `paths`. `base` is `--base`, taken as given.
    func target(_ scope: QualityScope, paths given: [String], base flag: String?, in ctx: WorktreeContext) async throws -> QualityTarget {
        let root = ctx.location.worktreeRoot
        let paths = try ScopePaths(given, from: currentDirectory, in: root)
        let finder = ChangeFinder(runner: runner)
        guard scope != .all else {
            return QualityTarget(scope: scope, base: nil, files: paths.narrow(try await finder.everyFile(in: root)), paths: paths)
        }
        let base = try await BaseResolver(runner: runner).resolve(in: root, flag: flag, recorded: ctx.state.base)
        let changed = try await finder.changed(in: root, since: base.forkPoint)
        return QualityTarget(scope: scope, base: base, files: paths.narrow(changed), paths: paths)
    }
}
