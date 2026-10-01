import ArgumentParser

struct GlobalOptions: ParsableArguments {
    @Flag(help: "Print one JSON object instead of text (also: XCD_OUTPUT=json).")
    var json = false

    @Option(help: "Act on this worktree of the current project instead of the one containing the current directory.")
    var worktree: String?
}
