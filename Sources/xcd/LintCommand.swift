import ArgumentParser
import XcdevKit

struct LintCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lint",
        abstract: "Lint the Swift files this worktree changed, with the project's own linter.",
        discussion: """
        The linter is the one the project names under `lint:` in .xcdev.yml: SwiftLint, or a command of its own.
          xcd lint                  the findings the change introduced, against the worktree's base
          xcd lint --files          every finding in the changed files
          xcd lint --all            every finding in the project
          xcd lint Sources/Login    any of them, only for these files and folders
        A finding the base version of a file already has is counted, not listed: `--files` lists it. The change is \
        the working tree against the commit where this work left its base: committed, staged, unstaged, and new \
        files. The command fails when a finding is an error; warnings are listed and it succeeds.
        """)
    @Argument(help: "Files or folders to narrow the scope to, read from the current directory.", completion: .file())
    var paths: [String] = []
    @Flag(help: "Show every finding in the changed files, not only the ones the change introduced.") var files = false
    @Flag(help: "Lint every Swift file in the project that git knows.") var all = false
    @Option(help: "Measure the change against this branch, tag, or commit instead of the worktree's base.") var base: String?
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("lint", options) { services in
            let request = LintOptions(paths: paths, files: files, all: all, base: base)
            _ = try request.scope()                                  // a mistake in the flags comes before anything is opened
            let ctx = try await services.open(worktree: options.worktree)
            return try await services.lint.lint(request, in: ctx)
        }
    }
}
