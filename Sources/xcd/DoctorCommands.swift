import ArgumentParser
import XcdevKit

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check simulators, worktrees, and this project's setup; --fix repairs what it can. Without --fix, changes nothing.")
    @Flag(help: "Repair the problems that have a fix (orphaned clones, stale worktrees, stuck simulators, …).") var fix = false
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("doctor", options) { services in
            await services.doctor.run(fix: fix, from: services.currentDirectory)
        }
    }
}

struct PruneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Delete orphans: clones no worktree owns and registry entries whose checkout is gone (`xcd doctor --fix`, orphans only).")
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("prune", options) { services in
            await services.doctor.run(fix: true, checks: DoctorService.pruneChecks, from: services.currentDirectory,
                                      includeDisk: false)
        }
    }
}
