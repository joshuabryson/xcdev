import ArgumentParser
import XcdevKit

struct FormatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "format",
        abstract: "Put the Swift code this worktree changed in the project's format.",
        discussion: """
        The formatter is the one the project names under `format:` in .xcdev.yml: SwiftFormat, Apple's swift-format, \
        or a command of its own.
          xcd format                  reformat the lines the change touched, against the worktree's base
          xcd format --files          reformat the changed files whole
          xcd format --all            reformat every Swift file in the project
          xcd format --check          write nothing: list what would change, and fail when something would
          xcd format Sources/Login    any of them, only for these files and folders
        The change is the working tree against the commit where this work left its base: committed, staged, \
        unstaged, and new files. A new file is formatted whole. Each file the formatter changed is listed with the \
        lines that differ. A file it cannot process is left as it was and listed with the formatter's own error, \
        and the command then fails.
        """)
    @Argument(help: "Files or folders to narrow the scope to, read from the current directory.", completion: .file())
    var paths: [String] = []
    @Flag(help: "Reformat the changed files whole, not only the lines the change touched.") var files = false
    @Flag(help: "Reformat every Swift file in the project that git knows.") var all = false
    @Option(help: "Measure the change against this branch, tag, or commit instead of the worktree's base.") var base: String?
    @Flag(help: "Write nothing. List what would change, and exit 1 when something would.") var check = false
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("format", options) { services in
            let request = FormatOptions(paths: paths, files: files, all: all, base: base, check: check)
            _ = try request.scope()                                  // a mistake in the flags comes before anything is opened
            let ctx = try await services.open(worktree: options.worktree)
            return try await services.format.format(request, in: ctx)
        }
    }
}
