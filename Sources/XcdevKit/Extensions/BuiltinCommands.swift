/// Names xcd keeps for its own commands, so a project command can never be shadowed by one.
/// It lists every built-in command and alias, plus names that later versions will use.
public enum BuiltinCommands {
    public static let reservedNames: Set<String> = [
        "build", "test", "run", "logs", "clean", "install", "uninstall", "launch", "terminate",
        "worktree", "wt", "sim", "config", "context", "init", "guide", "help", "doctor", "prune",
        "open", "lint", "ui", "debug",
    ]
}
