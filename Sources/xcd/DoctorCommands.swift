import ArgumentParser
import XcdevKit

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check simulators, worktrees, and this project's setup; --fix repairs this project's problems. Without a flag, changes nothing.")
    @Flag(help: "Repair this project's problems that have a fix, those of projects whose folders are gone, and xcd's own leftovers. Another project's problems say where to fix them.")
    var fix = false
    @Flag(name: .customLong("restart-simulators"),
          help: "Restart CoreSimulator if it isn't answering. Every booted simulator on this Mac shuts down, other agents' too: ask the user first.")
    var restartSimulators = false
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("doctor", options) { services in
            await services.doctor.run(fix: fix, restartSimulators: restartSimulators, from: services.currentDirectory)
        }
    }
}

struct PruneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Delete orphans of this project and of projects that are gone: clones no worktree owns and registry entries whose checkout is gone (`xcd doctor --fix`, orphans only).")
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("prune", options) { services in
            await services.doctor.run(fix: true, checks: DoctorService.pruneChecks, from: services.currentDirectory,
                                      includeDisk: false)
        }
    }
}
