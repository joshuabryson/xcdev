import ArgumentParser
import XcdevKit

extension UICommand {
    struct Menu: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List a Mac app's menu bar, or press one of its items by path.",
            discussion: """
            `xcd ui menu` prints every item as a path, like `File > Save…`, with `(disabled)` where it is. `xcd ui menu \
            "File > Save…"` presses that item through the Accessibility API, which is how a keyboard shortcut is used on a \
            Mac app driven in the background: posted ⌘-chords do not reach it. Mac devices only.
            """
        )
        @Argument(help: "The item to press, e.g. \"File > Save…\". Omit it to list the menu bar.") var path: String?
        @OptionGroup var menu: MenuOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let (path, ui) = (path, try menu.options())
            try await Emit.run("ui menu", options) { services in
                var ctx = try await services.open(worktree: options.worktree)
                await Recording.stopOverdue(services, ctx)
                return try await services.ui.menu(path, ui, in: &ctx)
            }
        }
    }

    /// The action options without `--system`: a Mac has no Home Screen, and `ui menu` is for Mac apps only.
    struct MenuOptions: ParsableArguments {
        @Flag(help: "Also print the tree as it is after the press. An element it lists keeps the ref it had.") var tree = false
        @Option(help: "How long to keep looking for the element, when the action names one, at most 120s (default: 2s).") var timeout: String?
        @Option(help: "Device name from .xcdev.yml (default: defaultDevice).", completion: .devices) var device: String?
        @Option(help: "Bundle id of the app to drive (default: the app of the last build for this device).") var bundle: String?

        func options() throws -> UIOptions {
            var options = UIOptions(device: device, bundle: bundle, system: false, role: nil, index: nil,
                                    timeout: try DurationText.option(timeout, flag: "--timeout") ?? .seconds(2))
            options.tree = tree
            return options
        }
    }
}
