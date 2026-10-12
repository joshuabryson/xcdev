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

extension XcdevConfig {
    public var lintSetup: LintSetup {
        guard let lint else { return .absent }
        if let run = lint.run { return .command(run) }
        switch lint.tool {
        case .swiftlint: return .swiftlint(path: lint.path, args: lint.args ?? [])
        case .off, nil: return .off
        }
    }
}
