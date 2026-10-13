import Foundation

/// What `xcd lint` was asked for.
public struct LintOptions: Sendable, Equatable {
    /// Files and folders that narrow the scope. Empty: no narrowing.
    public var paths: [String]
    /// `--files`: every finding in the changed files.
    public var files: Bool
    /// `--all`: every Swift file git knows.
    public var all: Bool
    /// `--base`: the ref the change is measured against.
    public var base: String?

    public init(paths: [String] = [], files: Bool = false, all: Bool = false, base: String? = nil) {
        self.paths = paths
        self.files = files
        self.all = all
        self.base = base
    }

    public func scope() throws -> QualityScope {
        try QualityScope.named(files: files, all: all, base: base, otherwise: "to see what the change introduced")
    }
}

/// `xcd lint`: lints the Swift files a worktree changed with whatever the project's `lint:`
/// section names.
public struct LintService: Sendable {
    static let swiftLint = "swiftlint"
    static let section = "lint"

    public let runner: any ProcessRunning
    public let locator: ToolLocator
    /// Where paths on the command line are read from.
    public let currentDirectory: String
    public let interrupts: Interrupts
    /// Passed to a project's own command as XCD_OUTPUT.
    public let output: OutputFormat
    public let now: @Sendable () -> Date

    public init(runner: any ProcessRunning, locator: ToolLocator, currentDirectory: String, interrupts: Interrupts,
                output: OutputFormat = .text, now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.locator = locator
        self.currentDirectory = currentDirectory
        self.interrupts = interrupts
        self.output = output
        self.now = now
    }

    /// The three states of the section: absent is `not_configured`, `tool: none` succeeds
    /// saying so, and a tool or a command runs.
    public func lint(_ options: LintOptions, in ctx: WorktreeContext) async throws -> LintReport {
        let scope = try options.scope()
        let hasConfigFile = QualityDetection.lintConfigFile(in: ctx.location.worktreeRoot) != nil
        switch ctx.config.lintSetup {
        case .absent:
            throw Self.notConfigured(hasConfigFile: hasConfigFile)
        case .off:
            return .off(scope: scope, hasConfigFile: hasConfigFile, worktree: ctx.state.name)
        case .swiftlint(let path, let args):
            return try await swiftLint(try await target(options, scope, in: ctx), path: path, args: args, in: ctx)
        case .command(let command):
            return try await ownCommand(command, try await target(options, scope, in: ctx), in: ctx)
        }
    }

    /// What the command says when the project never said whether it has a linter.
    static func notConfigured(hasConfigFile: Bool) -> XcdError {
        let add = "add `lint: { tool: swiftlint }` to .xcdev.yml"
        let next = hasConfigFile
            ? "\(SwiftLintConfig.fileName) found: run `xcd doctor --fix`, or \(add)"
            : "\(add), or `lint: { tool: none }` if the project has no linter"
        return XcdError(.notConfigured, "lint is not set up for this project", next: next)
    }

    /// The files in scope, found the way `xcd format` finds them too.
    func target(_ options: LintOptions, _ scope: QualityScope, in ctx: WorktreeContext) async throws -> QualityTarget {
        try await TargetFinder(runner: runner, currentDirectory: currentDirectory).target(scope, paths: options.paths, base: options.base, in: ctx)
    }

    func report(_ tool: String, _ scope: QualityScope, _ target: QualityTarget, in ctx: WorktreeContext) -> LintReport {
        LintReport(tool: tool, scope: scope, base: target.base?.name, baseCommit: target.base?.forkPoint, files: target.files.count,
                   worktree: ctx.state.name)
    }

    /// SwiftLint on the files in scope. Only the default scope compares with the fork point.
    func swiftLint(_ target: QualityTarget, path: String?, args: [String], in ctx: WorktreeContext) async throws -> LintReport {
        var report = report(Self.swiftLint, target.scope, target, in: ctx)
        guard !target.files.isEmpty else { return report.nothingInScope(under: target.paths.prefixes) }
        let root = ctx.location.worktreeRoot
        guard let executable = locator.locate(Self.swiftLint, path: path, worktreeRoot: root) else {
            throw ToolLocator.missing(Self.swiftLint, section: Self.section, path: path)
        }
        let started = now()
        let tool = SwiftLintTool(runner: runner, executable: executable, args: args)
        let linter = SwiftLintLinter(tool: tool, worktreeRoot: root, interrupts: interrupts)
        let result = try await linter.lint(target.files, against: target.scope == .lines ? target.base?.forkPoint : nil)
        report.findings = result.findings
        report.older = result.older
        report.notes = LintReport.toolNotes(result.notes, from: Self.swiftLint)
        report.log = ctx.paths.newArtifact(in: ctx.paths.logs, kind: Self.section, ext: "log", now: now())
        try result.transcript.write(toFile: report.log ?? "", atomically: true, encoding: .utf8)
        report.seconds = now().timeIntervalSince(started)
        return report
    }

    /// The project's own command on the files in scope. It sees whole files, so the default scope is the changed
    /// files. With `--all` and no paths it is handed no files and covers the project its own way.
    func ownCommand(_ command: String, _ target: QualityTarget, in ctx: WorktreeContext) async throws -> LintReport {
        var report = report(Self.firstLine(of: command), target.scope == .all ? .all : .files, target, in: ctx)
        guard !target.files.isEmpty else { return report.nothingInScope(under: target.paths.prefixes) }
        let files = target.scope == .all && target.paths.isEmpty ? [] : target.files.map(\.path)
        let started = now()
        let result = try await CommandTool(runner: runner, output: output, now: now).run(command, section: Self.section, files: files, in: ctx)
        report.notes = [CommandTool.unnamedFilesNote(command, section: Self.section, files: files.count)].compactMap { $0 }
        report.exitCode = result.exitCode
        report.output = result.output
        report.log = result.log
        report.seconds = now().timeIntervalSince(started)
        return report
    }

    /// A project's command as the result names it: its first line, trimmed, and ` …` when more lines follow. A
    /// command written as a YAML block (`run: |`) ends in a newline, and a script of several lines would land whole
    /// in the result's first line. Empty lines are not counted.
    static func firstLine(of command: String) -> String {
        let lines = command.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (lines.first ?? "") + (lines.count > 1 ? " …" : "")
    }
}
