import ArgumentParser
import XcdevKit

/// `xcd ui tree`, `tap`, `wait`, and `stop`: the commands that talk to the clone's UI runner.
extension UICommand {
    struct DrivingOptions: ParsableArguments {
        @Option(help: "Device name from .xcdev.yml (default: defaultDevice).", completion: .devices) var device: String?
        @Option(help: "Bundle id of the app to drive (default: the app of the last build for this device).") var bundle: String?
        @Flag(help: "Drive Springboard (the Home Screen) instead of an app.") var system = false

        func options(role: String? = nil, index: Int? = nil, timeout: String? = nil, defaultTimeout: Duration) throws -> UIOptions {
            if system, bundle != nil {
                throw XcdError(.usage, "--system and --bundle can't be combined", next: "pass one of them")
            }
            return UIOptions(device: device, bundle: bundle, system: system, role: role, index: index,
                             timeout: try DurationText.option(timeout, flag: "--timeout") ?? defaultTimeout)
        }
    }

    struct MatchOptions: ParsableArguments {
        @Option(help: "Only match elements with this role, e.g. button, textField, text, cell.", completion: .list(ElementRole.all))
        var role: String?
        @Option(help: "Pick one of several matches: 0 is the first.") var index: Int?
    }

    struct Tree: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the elements on screen, each with a ref (e1, e2, …) to act on.",
            discussion: "Each listing replaces the refs of the one before it. An app that isn't in front is reported as such, with Springboard's elements."
        )
        @Flag(help: "Include containers, keyboard keys, and off-screen elements.") var all = false
        @OptionGroup var driving: DrivingOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("ui tree", options) { services in
                var ctx = try await services.open(worktree: options.worktree)
                await Recording.stopOverdue(services, ctx)
                return try await services.ui.tree(all: all, try driving.options(defaultTimeout: .seconds(2)), in: &ctx)
            }
        }
    }

    struct Tap: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Tap an element or a point.",
            discussion: """
            The app must be running in front (`xcd run` or `xcd launch`; not needed with --system); a system alert over it \
            can be tapped too. \
            An element covered by an alert or the keyboard is not tapped. When several elements match, the failure \
            lists them as e1, e2, …: those become the refs, so `ref:e<N>` (or --index) picks one. \
            A tap that succeeds says where it landed, not what it did: check with `xcd ui wait` or `xcd ui tree`.
            """
        )
        @Argument(help: "What to tap, e.g. id:signInButton, \"label:Sign In\", ref:e4, or @120,300.") var target: String
        @OptionGroup var match: MatchOptions
        @Option(help: "How long to keep looking for the element, at most 120s (default: 2s).") var timeout: String?
        @OptionGroup var driving: DrivingOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("ui tap", options) { services in
                var ctx = try await services.open(worktree: options.worktree)
                await Recording.stopOverdue(services, ctx)
                let ui = try driving.options(role: match.role, index: match.index, timeout: timeout, defaultTimeout: .seconds(2))
                return try await services.ui.tap(target, ui, in: &ctx)
            }
        }
    }

    struct Wait: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Wait for an element to be on screen, or with --gone, to be gone.",
            discussion: "The app must be running in front (`xcd run` or `xcd launch`; not needed with --system). A point (@x,y) can't be waited for."
        )
        @Argument(help: "What to wait for, e.g. id:welcome or \"label~Welcome\".") var target: String
        @Flag(help: "Wait for it to go away instead.") var gone = false
        @OptionGroup var match: MatchOptions
        @Option(help: "How long to wait, at most 120s (default: 10s).") var timeout: String?
        @OptionGroup var driving: DrivingOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("ui wait", options) { services in
                var ctx = try await services.open(worktree: options.worktree)
                await Recording.stopOverdue(services, ctx)
                let ui = try driving.options(role: match.role, index: match.index, timeout: timeout, defaultTimeout: .seconds(10))
                return try await services.ui.wait(target, gone: gone, ui, in: &ctx)
            }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop this clone's UI runner (it starts again on the next ui command).")
        @Flag(help: "Also discard the cached runner build, so it is built again on next use.") var rebuild = false
        @OptionGroup var target: SimCommand.DeviceOption
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("ui stop", options) { services in
                var ctx = try await services.open(worktree: options.worktree)
                return try await services.ui.stop(device: target.device, rebuild: rebuild, in: &ctx)
            }
        }
    }
}
