extension ConfigSchema {
    /// `lint:`.
    static let lint: SchemaNode = .object("The project's linter, which `xcd lint` runs on the Swift files a change touched. It has exactly one of tool and run. The linter's own rules stay in its own file (.swiftlint.yml).", [
        SchemaField("tool", .string("The linter `xcd lint` runs: swiftlint, or none for a project that has no linter.", allowed: LintConfig.Tool.allCases.map(\.rawValue)),
                    example: "lint:\n  tool: swiftlint"),
        SchemaField("path", .string("Where the tool's executable is: an absolute path, or one relative to the worktree root. A path that differs per Mac belongs in .xcdev.local.yml. Only with a tool other than none."),
                    default: "the first swiftlint in PATH, then /opt/homebrew/bin, then /usr/local/bin",
                    example: "lint:\n  tool: swiftlint\n  path: tools/swiftlint"),
        SchemaField("args", .stringList("Extra arguments for the tool, placed after xcd's own. `--strict` makes SwiftLint report warnings as errors, so `xcd lint` fails on them. Only with a tool other than none."),
                    default: "none", example: "lint:\n  tool: swiftlint\n  args: [\"--strict\"]"),
        SchemaField("run", .string("The project's own lint command, in place of tool. A shell command run from the worktree root with the XCD_* context variables. The Swift files in scope are its arguments, and it names \"$@\" where they go: xcd adds nothing to the command, so one with no \"$@\" gets no files. Exit 0 means it passed."),
                    example: "lint:\n  run: ./scripts/lint.sh \"$@\""),
    ])

    /// `format:`.
    static let format: SchemaNode = .object("The project's formatter, which `xcd format` runs on the Swift code a change touched. It has exactly one of tool and run. The formatter's own rules stay in its own file (.swiftformat or .swift-format).", [
        SchemaField("tool", .string("The formatter `xcd format` runs: swift-format (Apple's, which ships inside Xcode), swiftformat (Nick Lockwood's SwiftFormat), or none for a project that has no formatter.", allowed: FormatConfig.Tool.allCases.map(\.rawValue)),
                    example: "format:\n  tool: swiftformat"),
        SchemaField("path", .string("Where the tool's executable is: an absolute path, or one relative to the worktree root. A path that differs per Mac belongs in .xcdev.local.yml. Only with a tool other than none."),
                    default: "swift-format: the one in the worktree's Xcode. swiftformat: the first in PATH, then /opt/homebrew/bin, then /usr/local/bin",
                    example: "format:\n  tool: swiftformat\n  path: tools/swiftformat"),
        SchemaField("args", .stringList("Extra arguments for the tool, placed after xcd's own. The formatter's rules belong in its own file, not here. Only with a tool other than none."),
                    default: "none", example: "format:\n  tool: swiftformat\n  args: [\"--config\", \"ci/.swiftformat\"]"),
        SchemaField("run", .string("The project's own format command, in place of tool. A shell command run from the worktree root with the XCD_* context variables. It rewrites the files itself. The Swift files in scope are its arguments, and it names \"$@\" where they go: xcd adds nothing to the command, so one with no \"$@\" gets no files. Exit 0 means it worked."),
                    example: "format:\n  run: ./scripts/format.sh \"$@\""),
        SchemaField("check", .string("What `xcd format --check` runs: a command that reports what it would change and rewrites nothing. It gets the files the way run does. Exit 0 means nothing needs formatting. Only with run."),
                    example: "format:\n  run: ./scripts/format.sh \"$@\"\n  check: ./scripts/format.sh --dry \"$@\""),
    ])
}
