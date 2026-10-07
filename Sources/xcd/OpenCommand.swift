import ArgumentParser
import XcdevKit

struct OpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open one of the project's routes, or a URL, in the app. With no argument, list the routes.",
        discussion: """
        Routes are the links the app can open, described under `deeplinks:` in .xcdev.yml.
          xcd open                        list the routes and their parameters
          xcd open item id=42 tab=notes   open a route (quote a value that has spaces)
          xcd open 'myapp://item?id=42'   open a link no route describes, sent as given
        Quote a link that has ? or & in it.
        The app is started if it is not running. Nothing is built or installed: run `xcd run` first.
        """)
    @Argument(help: ArgumentHelp("A route name, or a URL (anything with a `:` in it). After a route name: its parameters, each name=value.",
                                 valueName: "route-or-url"))
    var arguments: [String] = []
    @Option(help: "Restart the app with this launch preset first. Replaces the route's own preset.",
            completion: .project { await $0.presets() }) var preset: String?
    @Flag(help: "Stop the app and let the link start it, the way a link arrives when the app is not running.") var cold = false
    @Flag(name: .customLong("dry-run"), help: "Print what would be sent, and send nothing.") var dryRun = false
    @OptionGroup var target: TargetOptions
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        guard !arguments.isEmpty else {
            try await Emit.run("open", options) { services in
                services.routes.list(in: try await services.open(worktree: options.worktree, xcode: target.xcode))
            }
            return
        }
        try await Emit.run("open", options) { services in
            let request = try OpenRequest.parse(arguments)
            var ctx = try await services.open(worktree: options.worktree, xcode: target.xcode)
            if !dryRun { await Recording.stopOverdue(services, ctx) }
            return try await services.routes.open(request, OpenOptions(device: target.device, preset: preset, cold: cold, dryRun: dryRun),
                                                  in: &ctx)
        }
    }
}
