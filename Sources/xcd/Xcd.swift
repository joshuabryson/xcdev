import ArgumentParser
import Foundation
import XcdevKit

@main
struct Xcd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcd",
        abstract: "One entry point for agents doing Apple-platform development.",
        discussion: "Each git worktree gets its own simulators and build folders. Run commands from inside a project that has a .xcdev.yml.",
        version: XcdevVersion.current,
        subcommands: [WorktreeCommand.self, SimCommand.self, ConfigCommand.self, ContextCommand.self]
    )

    /// Parse errors become `usage` failures (exit 2, JSON envelope with --json / XCD_OUTPUT=json).
    /// Help, version, and the exit codes thrown by `Emit` pass through unchanged.
    static func main() async {
        do {
            var command = try parseAsRoot()
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
