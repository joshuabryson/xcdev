import ArgumentParser
import XcdevKit

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check simulators, worktrees, and this project's setup; --fix repairs this project's problems. Without a flag, changes nothing. --grant-accessibility and --grant-screen-recording ask macOS for a Mac grant, at the user's word.")
    @Flag(help: "Repair this project's problems that have a fix, those of projects whose folders are gone, and xcd's own leftovers. Another project's problems say where to fix them.")
    var fix = false
    @Flag(name: .customLong("restart-simulators"),
          help: "Restart CoreSimulator if it isn't answering. Every booted simulator on this Mac shuts down, other agents' too: ask the user first.")
    var restartSimulators = false
    @Flag(name: .customLong("grant-accessibility"),
          help: "Ask macOS to grant Accessibility to the app that runs xcd: the system prompt, then the System Settings pane if the switch is still off after 20s; waits up to 60s. It shows on the person's screen: only at the user's word.")
    var grantAccessibility = false
    @Flag(name: .customLong("grant-screen-recording"),
          help: "The same for Screen Recording; the app that runs xcd must then be quit and reopened. Only at the user's word.")
    var grantScreenRecording = false
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        guard grantAccessibility || grantScreenRecording else {
            return try await Emit.run("doctor", options) { services in
                await services.doctor.run(fix: fix, restartSimulators: restartSimulators, from: services.currentDirectory)
            }
        }
        try await Emit.run("doctor", options) { services in try await services.doctor.grant(grantKind()) }
    }

    /// One grant per run, and never with a fix. Thrown inside `Emit.run`, so it renders as a
    /// `usage` failure with this `next:`.
    func grantKind() throws -> MacGrantKind {
        guard !(grantAccessibility && grantScreenRecording), !fix, !restartSimulators else {
            throw XcdError(.usage, "one grant at a time, and not with --fix",
                           next: "run `xcd doctor --grant-accessibility` or `--grant-screen-recording` on its own")
        }
        return grantAccessibility ? .accessibility : .screenRecording
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
