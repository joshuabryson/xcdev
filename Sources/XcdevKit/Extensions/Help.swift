import Foundation

/// A built-in command as `xcd help` lists it. The CLI supplies these from its command tree.
public struct BuiltinCommandInfo: Codable, Sendable, Equatable {
    public let name: String
    public let aliases: [String]
    public let summary: String

    public init(name: String, aliases: [String], summary: String) {
        self.name = name
        self.aliases = aliases
        self.summary = summary
    }
}

/// `xcd help`: every built-in command, project command, plugin, and guide, one line each.
public struct HelpReport: Reportable {
    public struct ProjectCommand: Codable, Sendable, Equatable {
        public let name: String
        public let summary: String?
        public let run: String
        public let needs: [String]
    }

    public struct PluginEntry: Codable, Sendable, Equatable {
        public let name: String
        public let path: String
        public let summary: String?
    }

    public let version: String
    public let builtins: [BuiltinCommandInfo]
    public let projectCommands: [ProjectCommand]
    public let plugins: [PluginEntry]
    public let guides: [String]
    /// Why project commands may be missing (outside a project, or an invalid .xcdev.yml).
    public let note: String?
    /// Whether plugins were asked to describe themselves. Bare `xcd` lists them without running any.
    public let pluginsDescribed: Bool

    public var text: String {
        func rows(_ items: [(String, String)]) -> [String] {
            let width = max(12, (items.map(\.0.count).max() ?? 0) + 2)
            return items.map { "  " + $0.0.padding(toLength: width, withPad: " ", startingAt: 0) + $0.1 }
        }
        var lines = ["xcd \(version): one entry point for agents doing Apple-platform development.",
                     "Details: `xcd help <command>`. Error codes: `xcd help errors`. Guides: `xcd guide <topic>`.",
                     "", "commands:"]
        lines += rows(builtins.map { builtin in
            (builtin.name, (builtin.aliases.isEmpty ? "" : "(alias: \(builtin.aliases.joined(separator: ", "))) ") + builtin.summary)
        })
        lines.append("project commands (.xcdev.yml commands:):")
        lines += projectCommands.isEmpty
            ? ["  none" + (note == nil ? "; add them under `commands:` (see `xcd config explain commands`)" : "")]
            : rows(projectCommands.map { ($0.name, ($0.summary ?? $0.run) + ($0.needs.isEmpty ? "" : "  needs=\($0.needs.joined(separator: ","))")) })
        lines.append(pluginsDescribed ? "plugins (xcd-<name> on PATH):"
                                      : "plugins (xcd-<name> on PATH; `xcd help` shows what each does):")
        lines += plugins.isEmpty ? ["  none"] : rows(plugins.map { plugin in
            guard pluginsDescribed else { return (plugin.name, plugin.path) }
            return (plugin.name, (plugin.summary ?? "(no description)") + "  \(plugin.path)")
        })
        lines.append("guides: " + guides.joined(separator: ", "))
        if let note { lines.append("note: " + note) }
        return lines.joined(separator: "\n")
    }
}

/// `xcd help <command>`: a command's details. Built-in help text comes from the CLI.
public struct CommandHelpReport: Reportable {
    /// "built-in", "project command", or "plugin".
    public let kind: String
    public let name: String
    public let help: String

    public init(kind: String, name: String, help: String) {
        self.kind = kind
        self.name = name
        self.help = help
    }

    public var text: String { help }
}

public struct HelpService: Sendable {
    public let services: Services

    public init(services: Services) { self.services = services }

    /// Reads .xcdev.yml without opening the worktree, so it writes nothing. `describePlugins: false` (bare `xcd`)
    /// lists plugins by name without running them; otherwise each is asked for `--xcd-describe` (3s deadline).
    public func overview(builtins: [BuiltinCommandInfo], describePlugins: Bool = true) async -> HelpReport {
        var commands: [HelpReport.ProjectCommand] = []
        var note: String?
        do {
            if let config = try await ExternalCommands(services: services).projectConfig() {
                commands = (config.commands ?? [:]).sorted { $0.key < $1.key }.map { name, spec in
                    HelpReport.ProjectCommand(name: name, summary: spec.description, run: spec.run, needs: spec.needs ?? [])
                }
            } else {
                note = "not inside a project with a .xcdev.yml, so no project commands are listed (set one up: `xcd guide setup`)"
            }
        } catch let error as XcdError {
            note = "project commands are unavailable: \(error.message) (\(error.code.rawValue)); \(error.next ?? "fix .xcdev.yml")"
        } catch {
            note = "project commands are unavailable: \(error)"
        }
        let found = PluginFinder(environment: services.environment).plugins()
        let reserved = Set(builtins.flatMap { [$0.name] + $0.aliases }).union(commands.map(\.name))
        let reachable = found.filter { !reserved.contains($0.name) }
        let descriptions = describePlugins ? await PluginRunner(runner: services.runner).describe(reachable) : [:]
        return HelpReport(version: XcdevVersion.current, builtins: builtins, projectCommands: commands,
                          plugins: reachable.map { HelpReport.PluginEntry(name: $0.name, path: $0.path, summary: descriptions[$0.name]) },
                          guides: Guides.all.map(\.topic), note: note, pluginsDescribed: describePlugins)
    }

    /// Details of a project command or plugin named `name` (built-ins are the CLI's). Writes nothing.
    public func detail(_ name: String, builtins: [String]) async throws -> CommandHelpReport {
        let config = try await ExternalCommands(services: services).projectConfig()
        if let spec = config?.commands?[name] {
            var lines = ["xcd \(name) [args…]  (project command from .xcdev.yml)"]
            if let description = spec.description { lines.append(description) }
            lines.append("runs: \(spec.run) \"$@\"  (from the worktree root, with the XCD_* context variables)")
            lines.append("needs: " + ((spec.needs ?? []).isEmpty ? "nothing" : (spec.needs ?? []).joined(separator: ", ")))
            lines.append("timeout: " + DurationText.format(spec.timeoutDuration))
            return CommandHelpReport(kind: "project command", name: name, help: lines.joined(separator: "\n"))
        }
        if let plugin = PluginFinder(environment: services.environment).plugin(named: name) {
            let summary = await PluginRunner(runner: services.runner).describe([plugin])[name]
            let help = ["xcd \(name) [args…]  (plugin: \(plugin.path))", summary ?? "(the plugin doesn't describe itself)",
                        "its own help: `xcd \(name) --help`, if it has one"].joined(separator: "\n")
            return CommandHelpReport(kind: "plugin", name: name, help: help)
        }
        let known = builtins + ["errors"] + (config?.commands ?? [:]).keys.sorted()
            + PluginFinder(environment: services.environment).plugins().map(\.name)
        let close = Suggest.closest(to: name, in: known, limit: 3)
        throw XcdError(.usage, "no command named '\(name)'",
                       next: close.isEmpty ? "run `xcd help` to see every command"
                                           : "did you mean \(close.map { "`xcd help \($0)`" }.joined(separator: ", "))?")
    }
}
