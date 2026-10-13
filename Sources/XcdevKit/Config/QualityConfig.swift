/// `lint:`: the project's linter, or its own lint command. The config loader checks that a
/// section has exactly one of `tool` and `run`.
public struct LintConfig: Codable, Sendable, Equatable {
    /// The linters xcd knows how to run. `off` is written `none`: the project has no linter.
    public enum Tool: String, Codable, Sendable, CaseIterable {
        case swiftlint
        case off = "none"
    }

    public var tool: Tool?
    /// Where the tool's executable is: absolute, or relative to the worktree root.
    public var path: String?
    /// Extra arguments for the tool, after xcd's own.
    public var args: [String]?
    /// The project's own lint command, in place of `tool`.
    public var run: String?

    public init(tool: Tool? = nil, path: String? = nil, args: [String]? = nil, run: String? = nil) {
        self.tool = tool
        self.path = path
        self.args = args
        self.run = run
    }
}

/// What `xcd lint` does in a project.
public enum LintSetup: Sendable, Equatable {
    /// No `lint:` section: nobody has said whether the project has a linter.
    case absent
    /// `tool: none`: the project has no linter.
    case off
    case swiftlint(path: String?, args: [String])
    /// `run:`, the project's own command.
    case command(String)
}

/// A formatter xcd knows how to run.
public enum FormatterKind: String, Sendable, CaseIterable {
    /// Apple's swift-format, which ships inside Xcode.
    case appleSwiftFormat = "swift-format"
    /// Nick Lockwood's SwiftFormat.
    case swiftFormat = "swiftformat"

    /// The file in the project root that holds the formatter's rules.
    public var configFile: String { "." + rawValue }
}

/// `format:`: the project's formatter, or its own format command. The config loader checks that
/// a section has exactly one of `tool` and `run`.
public struct FormatConfig: Codable, Sendable, Equatable {
    /// What `tool` may say. `off` is written `none`: the project has no formatter.
    public enum Tool: String, Codable, Sendable, CaseIterable {
        case appleSwiftFormat = "swift-format"
        case swiftFormat = "swiftformat"
        case off = "none"

        /// The formatter this names. Nil for `none`.
        public var kind: FormatterKind? { FormatterKind(rawValue: rawValue) }
    }

    public var tool: Tool?
    /// Where the tool's executable is: absolute, or relative to the worktree root.
    public var path: String?
    /// Extra arguments for the tool, after xcd's own.
    public var args: [String]?
    /// The project's own format command, in place of `tool`. It rewrites files.
    public var run: String?
    /// What `xcd format --check` runs, beside `run`. It reports and rewrites nothing.
    public var check: String?

    public init(tool: Tool? = nil, path: String? = nil, args: [String]? = nil, run: String? = nil, check: String? = nil) {
        self.tool = tool
        self.path = path
        self.args = args
        self.run = run
        self.check = check
    }
}

/// What `xcd format` does in a project.
public enum FormatSetup: Sendable, Equatable {
    /// No `format:` section: nobody has said whether the project has a formatter.
    case absent
    /// `tool: none`: the project has no formatter.
    case off
    case tool(FormatterKind, path: String?, args: [String])
    /// `run:`, the project's own command, and `check:` when it has one.
    case command(run: String, check: String?)
}

extension XcdevConfig {
    public var formatSetup: FormatSetup {
        guard let format else { return .absent }
        if let run = format.run { return .command(run: run, check: format.check) }
        guard let kind = format.tool?.kind else { return .off }
        return .tool(kind, path: format.path, args: format.args ?? [])
    }

    public var lintSetup: LintSetup {
        guard let lint else { return .absent }
        if let run = lint.run { return .command(run) }
        switch lint.tool {
        case .swiftlint: return .swiftlint(path: lint.path, args: lint.args ?? [])
        case .off, nil: return .off
        }
    }
}
