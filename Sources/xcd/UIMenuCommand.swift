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
        @OptionGroup var action: ActionOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let (path, ui) = (path, try action.options())
            try await Emit.run("ui menu", options) { services in
                var ctx = try await services.open(worktree: options.worktree)
                await Recording.stopOverdue(services, ctx)
                return try await services.ui.menu(path, ui, in: &ctx)
            }
        }
    }
}
