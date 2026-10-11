import ArgumentParser
import XcdevKit

extension SimCommand {
    struct TextSize: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "text-size",
            abstract: "Set the device's text size (the Dynamic Type size), or print it.",
            discussion: "Sizes, smallest first: \(SimctlClient.textSizes.joined(separator: ", ")). A device starts at large."
        )
        @Argument(help: "The size to set, e.g. accessibility-large. With none, the current size is printed.",
                  completion: .list(SimctlClient.textSizes)) var size: String?
        @OptionGroup var target: DeviceOption
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("sim text-size", options) { services in
                var ctx = try await services.open(worktree: options.worktree)
                await Recording.stopOverdue(services, ctx)
                return try await services.deviceState.textSize(size, device: target.device, in: &ctx)
            }
        }
    }
}
