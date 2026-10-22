import ArgumentParser
import XcdevKit

extension SimCommand {
    struct Container: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the app's data container: a simulator's, or a sandboxed Mac app's under ~/Library/Containers.",
            discussion: """
            On a simulator the app must be installed on the clone (`xcd install` or `xcd run`), and `app`, `groups`, or an \
            app group's identifier name its other containers. On a Mac device nothing is booted: the path comes from the \
            built app's entitlements (the copy's container under `isolation: suffix`), and an app that is not sandboxed has \
            none, so the error says where its data is. The path is printed alone, so `ls "$(xcd sim container)/Documents"` \
            works. Ask again after the app was uninstalled: its data then has a new folder.
            """
        )
        @Argument(help: "data (the default), app (the installed .app), groups (every app group: its identifier, a tab, its path), or one app group's identifier.",
                  completion: .list(["data", "app", "groups"])) var container: String?
        @Option(help: "Bundle id (default: the app of the last build for this device). Simulators only.") var bundle: String?
        @OptionGroup var target: DeviceOption
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("sim container", options) { services in
                var ctx = try await services.open(worktree: options.worktree)
                await Recording.stopOverdue(services, ctx)
                return try await services.deviceState.container(container, bundle: bundle, device: target.device, in: &ctx)
            }
        }
    }
}
