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
        @Argument(help: "What to press, e.g. id:photo, \"label:Message\", e4 (a ref from the tree), or @120,300.") var target: String
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

    struct TypeText: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "type",
            abstract: "Type text into a field.",
            discussion: """
            With --into the field is tapped first; without it the text goes to whatever has keyboard focus. \
            The text is sent as key presses, with or without a keyboard on screen (`by keyboard` in the report). Only \
            when no keyboard comes up and the simulator can't say what has keyboard focus is it pasted instead, which \
            replaces the device's pasteboard (`by paste`). Typing that succeeds is not proof the field took the text: \
            check its value with --tree or `xcd ui tree`. Text starting with `-` goes after `--`.
            """
        )
        @Argument(help: "The text to type, at most 2000 characters. May be empty with --clear or --submit.") var text: String
        @Option(help: "The field to tap first, e.g. id:email or \"label:Search\".") var into: String?
        @Flag(help: "Select everything in the field and replace it.") var clear = false
        @Flag(help: "Press Return afterwards.") var submit = false
        @OptionGroup var match: MatchOptions
        @OptionGroup var action: ActionOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let (text, ui) = (text, try action.options(match))
            let typing = TypeOptions(into: into, clear: clear, submit: submit)
            try await UICommand.act("ui type", options) { service, ctx in try await service.type(text, typing, ui, in: &ctx) }
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

    struct Button: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Press a hardware button: home, action, or camera.",
            discussion: "`home` works on every device; `action` and `camera` only on device types that have the button. Volume and lock can't be pressed in a simulator."
        )
        @Argument(help: "home, action, or camera.", completion: .list(HardwareButton.allCases.map(\.rawValue))) var button: String
        @OptionGroup var action: ActionOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let (button, ui) = (button, try action.options())
            try await UICommand.act("ui button", options) { service, ctx in try await service.button(button, ui, in: &ctx) }
        }
    }

    struct Rotate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Rotate the device: portrait, portrait-upside-down, landscape-left, or landscape-right.",
            discussion: """
            An app that doesn't support the orientation stays as it is; the tree's first line says which orientation the \
            screen is in. On a foldable (iPhone Duo) the rotation goes through the simulator's pose pipeline, which the \
            device follows where it ignores XCUITest's; portrait-upside-down is not available there, and the command fails \
            with `posture_failed` when the simulator does not report the turn within 5 s.
            """
        )
        @Argument(help: "The orientation.", completion: .list(DeviceOrientation.allCases.map(\.rawValue))) var orientation: String
        @OptionGroup var action: ActionOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let (orientation, ui) = (orientation, try action.options())
            try await UICommand.actWithServices("ui rotate", options) { services, ctx in
                guard DeviceOrientation(rawValue: orientation) != nil else { return try await services.ui.rotate(orientation, ui, in: &ctx) }
                guard try await services.posture.isFoldable(device: ui.device, in: &ctx) else {
                    return try await services.ui.rotate(orientation, ui, in: &ctx)
                }
                var report = try await services.posture.rotate(orientation, ui, in: &ctx)
                if ui.tree { await services.ui.attachTreeAfterDeviceAction(to: &report, ui, in: &ctx) }
                return report
            }
        }
    }
}
