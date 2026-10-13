/// The result of `xcd format`.
public struct FormatReport: Reportable {
    /// What `tool` says for `format.tool: none`.
    public static let noTool = QualityHeadline.noTool

    /// A file the formatter changed, or with `--check` would change.
    public struct Changed: Encodable, Sendable, Equatable {
        public let file: String
        /// The lines that differ, numbered in the file as it is on disk when the command ends. Absent for a file a
        /// project's own command rewrote: xcd only knows that it changed.
        public let lines: [LineRange]?

        public init(file: String, lines: [LineRange]?) {
            self.file = file
            self.lines = lines
        }

        /// `Sources/App/Session.swift  lines 88-91, 120`. One line is `line 12`, and a file with none to name stands alone.
        var text: String {
            guard let lines, let first = lines.first else { return file }
            let one = lines.count == 1 && first.first == first.last
            return "\(file)  line\(one ? "" : "s") " + lines.map(\.text).joined(separator: ", ")
        }
    }

    /// A file the formatter could not process, which is left as it was.
    public struct Failed: Encodable, Sendable, Equatable {
        public let file: String
        /// The formatter's own lines, each naming the file.
        public let message: String

        public init(file: String, message: String) {
            self.file = file
            self.message = message
        }
    }

    /// What ran: `swift-format`, `swiftformat`, the first line of the project's own command, or `none`.
    public let tool: String
    public let scope: QualityScope
    /// The ref the change is measured against, and the commit where the work left it. Absent with `--all`.
    public let base: String?
    public let baseCommit: String?
    /// How many Swift files were in scope.
    public let files: Int
    /// `--check`: nothing was written.
    public let check: Bool
    public var changed: [Changed] = []
    public var failed: [Failed] = []
    public var notes: [String] = []
    /// Each run's command and what the tool said.
    public var log: String?
    public var seconds = 0.0
    /// For a project's own command: what it printed, and how it exited.
    public var output: String?
    public var exitCode: Int32?
    public let worktree: String
    /// Why nothing was formatted, for the first line. Not part of the JSON.
    var nothingInScope: String?

    public init(tool: String, scope: QualityScope, base: ResolvedBase?, files: Int, check: Bool, worktree: String) {
        self.tool = tool
        self.scope = scope
        self.base = base?.name
        baseCommit = base?.forkPoint
        self.files = files
        self.check = check
        self.worktree = worktree
    }

    public var envelopeWorktree: String? { worktree }

    enum CodingKeys: String, CodingKey {
        case tool, scope, base, baseCommit, files, check, changed, failed, notes, log, seconds, output, exitCode, worktree
    }

    public var text: String {
        var lines = [headline] + notes.map { "note: " + $0 }
        if let log, !notes.isEmpty || !failed.isEmpty { lines.append("log: \(log)") }
        if let output = output?.trimmingCharacters(in: .newlines), !output.isEmpty { lines.append(output) }
        lines += changed.map(\.text) + failed.map(\.message)
        return lines.joined(separator: "\n")
    }

    /// `format: 2 files reformatted  tool=swiftformat  files=3  base=main  0.6s`. With nothing formatted, only what
    /// and why.
    var headline: String {
        QualityHeadline(command: "format", tool: tool, files: files, base: base, seconds: seconds).text(summary)
    }

    var summary: String {
        if tool == Self.noTool { return "no formatter is set up" }
        if files == 0 { return nothingInScope ?? "no Swift files in scope" }
        if let exitCode, exitCode != 0 || check { return exitCode == 0 ? "passed" : "failed" }
        var parts: [String] = []
        if !changed.isEmpty { parts.append(QualityHeadline.count(changed.count, "file") + (check ? " need\(changed.count == 1 ? "s" : "") formatting" : " reformatted")) }
        if !failed.isEmpty { parts.append((parts.isEmpty ? QualityHeadline.count(failed.count, "file") : "\(failed.count)") + " could not be formatted") }
        return parts.isEmpty ? "nothing to reformat" : parts.joined(separator: ", ")
    }

    /// `format_failed` when a check found something to change, a file could not be processed, or the project's
    /// command exited non-zero.
    public var failure: XcdError? {
        if let exitCode, exitCode != 0 {
            let command = check ? "check command" : "format command"
            return XcdError(.formatFailed, "the project's \(command) exited \(exitCode)", next: check
                ? "run `xcd format` to reformat, then `xcd format --check` again" : "fix what it reports and run `xcd format` again")
        }
        if !failed.isEmpty {
            return XcdError(.formatFailed, "\(QualityHeadline.count(failed.count, "file")) could not be formatted",
                            next: "fix what the formatter says about \(failed.count == 1 ? "it" : "them") and run `xcd format` again")
        }
        guard check, !changed.isEmpty else { return nil }
        return XcdError(.formatFailed, "\(QualityHeadline.count(changed.count, "file")) need\(changed.count == 1 ? "s" : "") formatting",
                        next: "run `xcd format` to reformat \(changed.count == 1 ? "it" : "them")")
    }
}

extension FormatReport {
    /// This result, worded for no Swift file in scope. `paths` are the ones given, relative to the worktree root.
    public func nothingInScope(under paths: [String]) -> FormatReport {
        var report = self
        let wording = scope.nothingInScope(since: base, under: paths)
        report.nothingInScope = wording.summary
        if wording.changeHeldNone { report.notes = ["`xcd format --all` formats the whole project"] }
        return report
    }

    /// The result for `format.tool: none`. With a formatter's config file in the project, a note says which line
    /// turns the formatter on; with both files, that the project has to say which one it uses. `check` is `--check`.
    public static func off(scope: QualityScope, configured: [FormatterKind], check: Bool, worktree: String) -> FormatReport {
        var report = FormatReport(tool: noTool, scope: scope, base: nil, files: 0, check: check, worktree: worktree)
        if let only = configured.first, configured.count == 1 {
            report.notes = ["\(only.configFile) found: set `format.tool: \(only.rawValue)` in .xcdev.yml to have `xcd format` use it"]
        } else if !configured.isEmpty {
            let files = configured.map(\.configFile).joined(separator: " and ")
            report.notes = ["\(files) found: set `format.tool` in .xcdev.yml to the formatter the project uses to have `xcd format` run it"]
        }
        return report
    }
}
