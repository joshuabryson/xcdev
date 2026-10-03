import ArgumentParser
import XcdevKit

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Show the app's unified log on this worktree's device, or with --app its captured stdout/stderr.")
    @Option(help: "Device name from .xcdev.yml (default: defaultDevice).", completion: .devices) var device: String?
    @Option(help: "How far back to look, e.g. 30s, 2m, 1h.") var since = "2m"
    @Option(help: "default, info, or debug.", completion: .list(["default", "info", "debug"])) var level = "info"
    @Option(help: "Only messages containing this text (case-insensitive).") var grep: String?
    @Flag(help: "Stream new messages until --for elapses.") var follow = false
    @Option(name: .customLong("for"), help: "How long --follow streams (default 30s, at most logs.maxFollow).")
    var duration: String?
    @Flag(help: "Include Apple framework messages from the app's process.") var system = false
    @Option(help: "Show at most this many of the latest entries.") var limit = 200
    @Flag(help: "Show the latest launch's captured stdout/stderr instead.") var app = false
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("logs", options) { services in
            var ctx = try await services.open(worktree: options.worktree)
            let logOptions = try LogOptions.commandLine(device: device, since: since, level: level, grep: grep,
                                                        follow: follow, duration: duration, system: system,
                                                        limit: limit, app: app, maxFollow: ctx.config.maxLogFollow)
            return try await services.logs.logs(logOptions, in: &ctx)
        }
    }
}
