import ArgumentParser
import XcdevKit

/// `xcd ui long-press`, `type`, `swipe`, `button`, and `rotate`.
extension UICommand {
    struct LongPress: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "long-press",
            abstract: "Press and hold an element or a point.",
            discussion: "Like `xcd ui tap`, held for --duration. Check what it did with --tree, `xcd ui wait`, or `xcd ui tree`."
        )
        @Argument(help: "What to press, e.g. id:photo, \"label:Message\", ref:e4, or @120,300.") var target: String
        @Option(help: "How long to hold, from 0.1s to 20s (default: 1s).") var duration: String?
        @OptionGroup var match: MatchOptions
        @OptionGroup var action: ActionOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let (target, ui) = (target, try action.options(match))
            let held = try DurationText.option(duration, flag: "--duration") ?? .seconds(1)
            try await UICommand.act("ui long-press", options) { service, ctx in
                try await service.longPress(target, duration: held, ui, in: &ctx)
            }
        }
    }

    struct Swipe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Swipe in a direction, or from one point to another.",
            discussion: """
            The direction is the way the finger moves: `up` scrolls a list down, towards its end. A direction swipe \
            starts at the centre of the --on element (or of the screen) and covers two fifths of its height or width. \
            To bring an off-screen element into view, swipe, then read the tree again.
            """
        )
        @Argument(help: "up, down, left, or right.", completion: .list(SwipeDirection.allCases.map(\.rawValue))) var direction: String?
        @Option(help: "The element to swipe across, e.g. id:feedList (default: the screen).") var on: String?
        @Option(help: "Start point x,y in points (with --to, instead of a direction).") var from: String?
        @Option(help: "End point x,y in points.") var to: String?
        @OptionGroup var match: MatchOptions
        @OptionGroup var action: ActionOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let ui = try action.options(match)
            let swipe = SwipeOptions(direction: direction, on: on, from: from, to: to)
            try await UICommand.act("ui swipe", options) { service, ctx in try await service.swipe(swipe, ui, in: &ctx) }
        }
    }
}
