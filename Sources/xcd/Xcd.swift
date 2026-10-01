import ArgumentParser
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
}
