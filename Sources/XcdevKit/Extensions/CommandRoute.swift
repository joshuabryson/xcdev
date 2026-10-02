/// How `xcd <args…>` is dispatched before ArgumentParser sees it.
public enum CommandRoute: Equatable, Sendable {
    /// A built-in command (or a flag such as --version): ArgumentParser handles it.
    case builtin
    /// `xcd`, `xcd help`, `xcd help <topic…>`. `json` is whether --json was among the arguments.
    case help(topic: [String], json: Bool)
    /// Anything else: a project command or a plugin, with the arguments after its name passed through untouched.
    case external(name: String, arguments: [String])

    /// `arguments` excludes argv[0]. `builtins` holds every built-in name and alias.
    public static func route(_ arguments: [String], builtins: Set<String>) -> CommandRoute {
        guard let first = arguments.first else { return .help(topic: [], json: false) }
        if first == "help" {
            let rest = Array(arguments.dropFirst())
            return .help(topic: rest.filter { $0 != "--json" }, json: rest.contains("--json"))
        }
        if first.hasPrefix("-") || builtins.contains(first) { return .builtin }
        return .external(name: first, arguments: Array(arguments.dropFirst()))
    }
}
