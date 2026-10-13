/// Names xcd keeps for its own commands, so a project command can never be shadowed by one.
/// It lists every built-in command and alias, `errors` (so `xcd help errors` stays xcd's), plus names that
/// later versions will use.
public enum BuiltinCommands {
    public static let reservedNames: Set<String> = [
        "build", "test", "run", "logs", "clean", "install", "uninstall", "launch", "terminate",
        "worktree", "wt", "sim", "config", "context", "init", "guide", "help", "doctor", "prune",
        "errors", "open", "lint", "format", "ui", "debug",
    ]

    /// Built-in commands that run a script the project names in a config section of the same name (`lint: { run: … }`).
    public static let sectionNames: Set<String> = ["lint", "format"]
}
