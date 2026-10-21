import ArgumentParser
import Foundation
import XcdevKit

@main
struct Xcd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcd",
        abstract: "One entry point for agents doing Apple-platform development.",
        discussion: "Each git worktree gets its own simulators and build folders. Run commands from inside a project that has a .xcdev.yml. `xcd help` lists every command, including project commands and plugins.",
        version: XcdevVersion.current,
        subcommands: [BuildCommand.self, TestCommand.self, RunCommand.self, LogsCommand.self, CleanCommand.self,
                      InstallCommand.self, UninstallCommand.self, LaunchCommand.self, TerminateCommand.self, OpenCommand.self,
                      XcodeCommand.self, WorktreeCommand.self, SimCommand.self, UICommand.self, ConfigCommand.self, ContextCommand.self, InitCommand.self,
                      GuideCommand.self, DoctorCommand.self, PruneCommand.self, LintCommand.self, FormatCommand.self,
                      RecordWindowCommand.self]
    )

    /// Built-in commands as `xcd help` lists them, from the command tree; a hidden one (`_record-window`) is left out.
    static var builtins: [BuiltinCommandInfo] {
        configuration.subcommands.filter { $0.configuration.shouldDisplay }.map {
            BuiltinCommandInfo(name: $0._commandName, aliases: $0.configuration.aliases, summary: $0.configuration.abstract)
        }
    }

    /// Every name ArgumentParser runs, the hidden commands' included.
    static var builtinNames: Set<String> {
        Set(configuration.subcommands.flatMap { [$0._commandName] + $0.configuration.aliases }).union(["help"])
    }

    /// `xcd help …` and unknown command names are handled here; everything else goes to ArgumentParser.
    /// Ctrl-C and SIGTERM are handled for every command from the start (see `Interrupts`), except in the window
    /// recorder: on SIGINT it takes no more stills and finishes its MP4, which the handler would pre-empt (it exits 130 at once).
    static func main() async {
        assert(builtinNames.isSubset(of: BuiltinCommands.reservedNames), "add new built-in names to BuiltinCommands.reservedNames")
        signal(SIGPIPE, SIG_IGN)    // a reader that went away is EPIPE, not death; children get SIGPIPE back
        if CommandLine.arguments.dropFirst().first == MacWindowRecorder.marker {
            await runBuiltin()
            return
        }
        Interrupts.shared.install()
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch CommandRoute.route(arguments, builtins: builtinNames) {
        case .builtin:
            await runBuiltin()
        case .help(let topic, let json):
            await HelpCommand.run(topic: topic, json: json, describePlugins: !arguments.isEmpty)
        case .external(let name, let rest):
            await External.run(name, arguments: rest)
        }
    }

    /// Parse errors become `usage` failures (exit 2, JSON envelope with --json / XCD_OUTPUT=json).
    /// Help, version, and the exit codes thrown by `Emit` pass through unchanged.
    static func runBuiltin() async {
        do {
            var command = try await asyncParseAsRoot()
            if var async = command as? AsyncParsableCommand {
                try await async.run()
            } else {
                try command.run()
            }
        } catch {
            if error is ExitCode || exitCode(for: error) == .success {
                exit(withError: error)
            }
            print(Renderer.usageFailure(message: fullMessage(for: error),
                                        arguments: Array(CommandLine.arguments.dropFirst()),
                                        environment: ProcessInfo.processInfo.environment))
            exit(withError: ExitCode(ErrorCode.usage.exitCode))
        }
    }
}
