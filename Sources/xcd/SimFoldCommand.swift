import ArgumentParser
import XcdevKit

extension SimCommand {
    struct Fold: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open, half-open, or close a foldable's hinge, or report its posture. Only a foldable (iPhone Duo) has a hinge.",
            discussion: """
            Without an argument, prints the posture, the active display, and the orientation. `closed`, `half`, and `open` \
            set the hinge to 0°, 90°, and 180°; --angle sets any angle from 0° to 180°, verified when the simulator \
            reports its own angle within 1° of it, which in practice is only those three. The command waits up to 5 s \
            for the simulator to show the new posture and says `unverified` when only the display agreed. Nothing is \
            brought to the foreground. Rotate a foldable with `xcd ui rotate`, \
            which takes the same route.
            """)
        @Argument(help: "closed, half, or open (default: report the posture).",
                  completion: .list(Posture.allCases.map(\.rawValue))) var posture: String?
        @Option(help: "The hinge angle in degrees, 0 (closed) to 180 (open flat), instead of a posture word. The simulator reports its own nearest angle and the request is verified when that is within 1°, which in practice is 0, 90, and 180; any other angle is sent and reported unverified with the angle the simulator shows.")
        var angle: Double?
        @Option(help: "The route to use (default: the first available): direct.",
                completion: .list(PostureRouteID.allCases.map(\.rawValue))) var route: String?
        @OptionGroup var target: DeviceOption
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("sim fold", options) { services in
                let fold = try FoldOptions.parse(posture: posture, angle: angle, route: route, device: target.device)
                var ctx = try await services.open(worktree: options.worktree)
                await Recording.stopOverdue(services, ctx)
                return try await services.posture.fold(fold, in: &ctx)
            }
        }
    }
}
