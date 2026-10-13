import Foundation

/// What `xcd format` was asked for.
public struct FormatOptions: Sendable, Equatable {
    /// Files and folders that narrow the scope. Empty: no narrowing.
    public var paths: [String]
    /// `--files`: the changed files, whole.
    public var files: Bool
    /// `--all`: every Swift file git knows.
    public var all: Bool
    /// `--base`: the ref the change is measured against.
    public var base: String?
    /// `--check`: say what would change, and write nothing.
    public var check: Bool

    public init(paths: [String] = [], files: Bool = false, all: Bool = false, base: String? = nil, check: Bool = false) {
        self.paths = paths
        self.files = files
        self.all = all
        self.base = base
        self.check = check
    }

    public func scope() throws -> QualityScope {
        try QualityScope.named(files: files, all: all, base: base, otherwise: "to reformat only the lines the change touched")
    }
}

/// `xcd format`: puts the Swift code a worktree changed in the project's format, with whatever
/// the project's `format:` section names.
public struct FormatService: Sendable {
    static let section = FormatterLocator.section
    /// How many formatter processes run at once.
    public static let mostAtOnce = 8

    public let host: QualityHost
    public var atOnce = FormatService.mostAtOnce

    public init(_ host: QualityHost) { self.host = host }

    /// The three states of the section: absent is `not_configured`, `tool: none` succeeds
    /// saying so, and a tool or a command runs.
    public func format(_ options: FormatOptions, in ctx: WorktreeContext) async throws -> FormatReport {
        let scope = try options.scope()
        let configured = QualityDetection.formatters(configuredIn: ctx.location.worktreeRoot)
        let finder = host.targets
        switch ctx.config.formatSetup {
        case .absent:
            throw Self.notConfigured(configured)
        case .off:
            return .off(scope: scope, configured: configured, check: options.check, worktree: ctx.state.name)
        case .tool(let kind, let path, let args):
            let target = try await finder.target(scope, paths: options.paths, base: options.base, in: ctx)
            return try await formatter(Named(kind: kind, path: path, args: args), target, check: options.check, in: ctx)
        case .command(let run, let check):
            let command = try Self.command(run: run, check: check, checking: options.check)
            let target = try await finder.target(scope, paths: options.paths, base: options.base, in: ctx)
            return try await ownCommand(command, target, check: options.check, in: ctx)
        }
    }

    /// What the command says when the project never said whether it has a formatter.
    static func notConfigured(_ configured: [FormatterKind]) -> XcdError {
        let line = { (tool: String) in "`format: { tool: \(tool) }`" }
        let next: String
        if let only = configured.first, configured.count == 1 {
            next = "\(only.configFile) found: run `xcd doctor --fix`, or add \(line(only.rawValue)) to .xcdev.yml"
        } else if configured.isEmpty {
            next = "add \(line(FormatterKind.appleSwiftFormat.rawValue)) to .xcdev.yml for Xcode's formatter, which indents with 2 spaces "
                + "unless the project adds a .swift-format file, or \(line(FormatReport.noTool)) if the project has no formatter"
        } else {
            next = configured.map(\.configFile).joined(separator: " and ") + " found: add "
                + configured.map { line($0.rawValue) }.joined(separator: " or ") + " to .xcdev.yml, whichever the project uses"
        }
        return XcdError(.notConfigured, "format is not set up for this project", next: next)
    }

    func report(_ tool: String, _ target: QualityTarget, check: Bool, in ctx: WorktreeContext) -> FormatReport {
        FormatReport(tool: tool, scope: target.scope, base: target.base, files: target.files.count, check: check, worktree: ctx.state.name)
    }
}

// MARK: A named formatter

extension FormatService {
    /// A formatter as the config names it.
    struct Named {
        let kind: FormatterKind
        let path: String?
        let args: [String]
    }

    /// The formatter on the files in scope: the lines the change touched in the default scope, and whole files
    /// otherwise. Each file is one formatter process, or one per range with SwiftFormat.
    func formatter(_ named: Named, _ target: QualityTarget, check: Bool, in ctx: WorktreeContext) async throws -> FormatReport {
        var report = report(named.kind.rawValue, target, check: check, in: ctx)
        guard !target.files.isEmpty else { return report.nothingInScope(under: target.paths.prefixes) }
        let root = ctx.location.worktreeRoot
        let place = FormatterLocator(tools: host.locator, runner: host.runner)
        let developerDir = try await place.developerDir(for: named.kind, path: named.path, pinned: ctx.xcode?.developerDir,
                                                        spec: ctx.config.xcode)
        guard let executable = await place.locate(named.kind, path: named.path, worktreeRoot: root, developerDir: developerDir) else {
            throw FormatterLocator.missing(named.kind, path: named.path)
        }
        let started = host.now()
        let scratch = try ScratchFolder.create(for: Self.section, removedBy: host.interrupts)
        defer { scratch.remove() }
        let tool: any FormatterTool = named.kind == .swiftFormat
            ? SwiftFormatTool(runner: host.runner, executable: executable, args: named.args, worktreeRoot: root, scratch: scratch)
            : AppleSwiftFormatTool(runner: host.runner, executable: executable, args: named.args, worktreeRoot: root)
        let one = FileFormatter(tool: tool, worktreeRoot: root, check: check, interrupts: host.interrupts)
        let files = try await each(target.files) { file in try await formatted(file, by: one, in: target, root) }
        let transcript = files.map(\.transcript).joined()
        report.fill(from: files, tool: named.kind.rawValue)
        report.log = transcript.isEmpty ? nil : writeLog(transcript, in: ctx)
        report.seconds = host.now().timeIntervalSince(started)
        return report
    }

    /// `file` formatted, or listed as one that could not be processed when git cannot say which of its lines changed.
    /// That is the file's failure and not the command's: the other files are still formatted.
    func formatted(_ file: ScopedFile, by one: FileFormatter, in target: QualityTarget, _ root: String) async throws -> FormattedFile {
        let changed: ChangedPart
        do {
            changed = try await part(of: file, in: target, root)
        } catch let error as XcdError where error.code == .subprocessFailed || error.code == .timeout {
            let why = error.details.dropFirst(2).last.map { ": " + $0 } ?? ""
            let line = "\(file.path): git could not say which of its lines changed, so it was left as it was" + why
            return one.failed(FormattedFile(path: file.path), [line])
        }
        return try await one.format(file.path, changed)
    }

    /// How much of `file` to format: the lines the change touched when the scope is the change, else all of it.
    func part(of file: ScopedFile, in target: QualityTarget, _ root: String) async throws -> ChangedPart {
        guard target.scope == .lines, let base = target.base else { return .whole }
        return try await ChangedLines(runner: host.runner).part(of: file, in: root, since: base.forkPoint)
    }

    /// `work` on each file, up to `atOnce` at a time. The results are in the files' order.
    func each(_ files: [ScopedFile], _ work: @escaping @Sendable (ScopedFile) async throws -> FormattedFile) async throws -> [FormattedFile] {
        try await withThrowingTaskGroup(of: (Int, FormattedFile).self) { group in
            var results = [FormattedFile?](repeating: nil, count: files.count)
            var waiting = Array(files.indices.reversed())
            var running = 0
            while !waiting.isEmpty || running > 0 {
                while running < atOnce, let index = waiting.popLast() {
                    group.addTask { (index, try await work(files[index])) }
                    running += 1
                }
                if let (index, file) = try await group.next() { results[index] = file }
                running -= 1
            }
            return results.compactMap { $0 }
        }
    }

    /// Writes what the formatter runs said to a log, and returns its path. A log that cannot be written is no
    /// reason to lose a result whose files are already formatted.
    func writeLog(_ transcript: String, in ctx: WorktreeContext) -> String? {
        let log = ctx.paths.newArtifact(in: ctx.paths.logs, kind: Self.section, ext: "log", now: host.now())
        return (try? transcript.write(toFile: log, atomically: true, encoding: .utf8)) == nil ? nil : log
    }
}

extension FormatReport {
    /// What happened to each file, as this result has it: the changed ones with their lines, the ones the formatter
    /// could not process with its lines about them, and as notes what `tool` warned of (each line once) and what
    /// was left alone.
    mutating func fill(from files: [FormattedFile], tool: String) {
        changed = files.compactMap { file in file.lines.map { Changed(file: file.path, lines: $0) } }
        failed = files.compactMap { file in file.failure.map { Failed(file: file.path, message: $0.joined(separator: "\n")) } }
        var said: [String] = []
        for line in files.flatMap(\.said) where !said.contains(line) { said.append(line) }
        notes = LintReport.toolNotes(said, from: tool) + files.compactMap(\.note)
    }
}

// MARK: A project's own command

extension FormatService {
    /// The command to run: `format.run`, or `format.check` for `--check`. A project that has no `check` cannot be
    /// checked, and `run` is never run in its place: it rewrites files.
    static func command(run: String, check: String?, checking: Bool) throws -> String {
        guard checking else { return run }
        guard let check else {
            throw XcdError(.notConfigured, "this project's format command has no check: format.check is not set",
                           next: "add `check:` beside `run:` under `format:` in .xcdev.yml: a command that reports what `run` would change and rewrites nothing")
        }
        return check
    }

    /// The project's own command on the files in scope. It sees whole files, so the default scope is the changed
    /// files. With `--all` and no paths it is handed no files and covers the project its own way. xcd reads the
    /// files in scope before and after a `run`, and lists the ones that differ.
    func ownCommand(_ command: String, _ target: QualityTarget, check: Bool, in ctx: WorktreeContext) async throws -> FormatReport {
        var report = FormatReport(tool: LintService.firstLine(of: command), scope: target.scope == .all ? .all : .files, base: target.base,
                                  files: target.files.count, check: check, worktree: ctx.state.name)
        guard !target.files.isEmpty else { return report.nothingInScope(under: target.paths.prefixes) }
        let root = ctx.location.worktreeRoot
        let handed = target.scope == .all && target.paths.isEmpty ? [] : target.files.map(\.path)
        let started = host.now()
        let before = check ? nil : FileStamps(of: target.files.map(\.path), in: root)
        var tool = CommandTool(runner: host.runner, output: host.output, now: host.now)
        tool.key = check ? "check" : "run"
        let result = try await tool.run(command, section: Self.section, files: handed, in: ctx)
        report.changed = (before?.changed(in: root) ?? []).map { FormatReport.Changed(file: $0, lines: nil) }
        report.notes = [CommandTool.unnamedFilesNote(command, section: Self.section, files: handed.count, key: tool.key)].compactMap { $0 }
        report.exitCode = result.exitCode
        report.output = result.output
        report.log = result.log
        report.seconds = host.now().timeIntervalSince(started)
        return report
    }
}
