import ArgumentParser
import Foundation
import XcdevKit

/// `xcd help [<command>… | errors] [--json]`. Routed before ArgumentParser, which has its own `help`.
/// Bare `xcd` prints the same list but passes `describePlugins: false`, so it runs no plugin.
enum HelpCommand {
    static func run(topic: [String], json: Bool, describePlugins: Bool = true) async {
        do {
            let options = try GlobalOptions.parse(json ? ["--json"] : [])
            if topic.isEmpty {
                try await Emit.run("help", options) { services in
                    await services.help.overview(builtins: Xcd.builtins, describePlugins: describePlugins)
                }
            } else if topic == ["errors"] {
                try await Emit.run("help errors", options) { _ in ErrorsReport() }
            } else if let command = builtin(topic) {
                try await Emit.run("help", options) { _ in
                    CommandHelpReport(kind: "built-in", name: topic.joined(separator: " "),
                                      help: Xcd.helpMessage(for: command, columns: 100))
                }
            } else {
                try await Emit.run("help", options) { services in
                    try await services.help.detail(topic[0], builtins: Xcd.builtins.map(\.name))
                }
            }
        } catch {
            Xcd.exit(withError: error)
        }
    }

    /// The built-in command at `path` (e.g. ["wt", "create"]), matching names and aliases.
    static func builtin(_ path: [String]) -> ParsableCommand.Type? {
        var candidates = Xcd.configuration.subcommands
        var found: ParsableCommand.Type?
        for name in path {
            guard let next = candidates.first(where: { $0._commandName == name || $0.configuration.aliases.contains(name) }) else {
                return nil
            }
            found = next
            candidates = next.configuration.subcommands
        }
        return found
    }
}

/// `xcd <name> [args…]` for a project command or plugin: their output and exit code pass straight through. A
/// command ended by a signal exits 128 + the signal (130 after Ctrl-C), as a shell reports it.
enum External {
    static func run(_ name: String, arguments: [String]) async {
        let services = Services.live()
        do {
            let code = try await services.externalCommands.run(name, arguments: arguments,
                                                               builtins: Xcd.builtins.map(\.name))
            Foundation.exit(code)
        } catch let error as XcdError {
            await services.interrupts.output { print(Renderer.failure(error, command: name, format: services.output)) }
            Foundation.exit(error.code.exitCode)
        } catch {
            let wrapped = XcdError(.internalError, "\(error)", next: "this is a bug in xcd; please report it")
            await services.interrupts.output { print(Renderer.failure(wrapped, command: name, format: services.output)) }
            Foundation.exit(wrapped.code.exitCode)
        }
    }
}
