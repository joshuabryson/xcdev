import Foundation

/// Lints Swift files with SwiftLint, never in the worktree itself: each run happens in a scratch folder that holds
/// copies of the files and of the lint config. Against a fork point, the files that have
/// findings are linted a second time as they were there, and only what the change introduced is shown.
public struct SwiftLintLinter: Sendable {
    public struct Result: Sendable, Equatable {
        /// The findings to show, in path, line, and column order.
        public let findings: [LintFinding]
        /// How many findings the files already had at the fork point. Zero when there is no fork point.
        public let older: Int
        /// What SwiftLint wrote to stderr when it linted the working tree's files.
        public let notes: [String]
        /// Each run's command and raw output, for the log.
        public let transcript: String
    }

    public let tool: SwiftLintTool
    public let worktreeRoot: String
    public let interrupts: Interrupts

    public init(tool: SwiftLintTool, worktreeRoot: String, interrupts: Interrupts) {
        self.tool = tool
        self.worktreeRoot = worktreeRoot
        self.interrupts = interrupts
    }

    /// `forkPoint` nil shows every finding (`--files`, `--all`).
    public func lint(_ files: [ScopedFile], against forkPoint: String?) async throws -> Result {
        var contents: [String: Data] = [:]
        for file in files {
            contents[file.path] = try? Data(contentsOf: URL(fileURLWithPath: worktreeRoot + "/" + file.path))
        }
        let current = try await run(on: contents)
        let found = Dictionary(grouping: current.findings, by: \.file)
        guard let forkPoint else {
            return Result(findings: Self.ordered(current.findings), older: 0, notes: current.notes, transcript: current.transcript)
        }
        let based = files.filter { found[$0.path] != nil && $0.basePath != nil }
        let base = try await lintBase(of: based, at: forkPoint)
        let fresh = files.flatMap { file -> [LintFinding] in
            guard let findings = found[file.path], let data = contents[file.path] else { return [] }
            return FindingComparison.newFindings(in: FileFindings(text: Self.text(data), findings: findings), against: base.versions[file.path])
        }
        return Result(findings: Self.ordered(fresh), older: current.findings.count - fresh.count, notes: current.notes,
                      transcript: current.transcript + base.transcript)
    }

    /// The base versions of `files`, each linted as it was at `forkPoint`, keyed by the file's path today. A file
    /// git cannot show there has no version, so all of its findings count as new.
    func lintBase(of files: [ScopedFile], at forkPoint: String) async throws -> (versions: [String: FileFindings], transcript: String) {
        var contents: [String: Data] = [:]
        for file in files {
            guard let path = file.basePath else { continue }
            let shown = try await tool.runner.run(.git(["show", "\(forkPoint):\(path)"], in: worktreeRoot))
            if shown.succeeded { contents[path] = shown.stdout }
        }
        guard !contents.isEmpty else { return ([:], "") }
        let base = try await run(on: contents)
        let found = Dictionary(grouping: base.findings, by: \.file)
        var versions: [String: FileFindings] = [:]
        for file in files {
            guard let path = file.basePath, let data = contents[path] else { continue }
            versions[file.path] = FileFindings(text: Self.text(data), findings: found[path] ?? [])
        }
        return (versions, "\n" + base.transcript)
    }

    /// One SwiftLint run on `contents` (path to the file's bytes, copied as they are) in a scratch folder of its
    /// own, which is removed afterwards, also when the run fails or the command is interrupted.
    func run(on contents: [String: Data]) async throws -> SwiftLintRun {
        let folder = try LintFolder.create()
        let cleanup = interrupts.addCleanup { folder.remove() }
        defer {
            interrupts.removeCleanup(cleanup)
            folder.remove()
        }
        for (path, data) in contents { try folder.write(data, to: path) }
        try folder.copyConfig(from: worktreeRoot, for: Array(contents.keys), args: tool.args)
        return try await tool.lint(folder)
    }

    /// A file's text, for telling one line from another. Bytes that are not UTF-8 are replaced: SwiftLint reports
    /// nothing for such a file anyway.
    static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    static func ordered(_ findings: [LintFinding]) -> [LintFinding] {
        findings.sorted { ($0.file, $0.line ?? 0, $0.column ?? 0, $0.rule) < ($1.file, $1.line ?? 0, $1.column ?? 0, $1.rule) }
    }
}
