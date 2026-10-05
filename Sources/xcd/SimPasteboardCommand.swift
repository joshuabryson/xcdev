import ArgumentParser
import XcdevKit

extension SimCommand {
    struct Pasteboard: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set the device's pasteboard (text or an image), or read its text.",
                                                        subcommands: [Set.self, GetText.self])

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "set",
                abstract: "Put text or an image on the device's pasteboard.",
                discussion: "An image goes through the UI runner, so it needs an iPhone or iPad simulator. There is no way to read an image back."
            )
            @Option(help: "The text. A value starting with `-` is written `--text=-n`.") var text: String?
            @Option(help: "A PNG or JPEG file (iPhone and iPad simulators).", completion: .file()) var image: String?
            @OptionGroup var target: DeviceOption
            @OptionGroup var options: GlobalOptions

            func run() async throws {
                try await Emit.run("sim pasteboard set", options) { services in
                    var ctx = try await services.open(worktree: options.worktree)
                    await Recording.stopOverdue(services, ctx)
                    switch (text, image) {
                    case (let text?, nil):
                        return try await services.deviceState.setPasteboard(text: text, device: target.device, in: &ctx)
                    case (nil, let image?):
                        let file = image.hasPrefix("/") ? image : services.currentDirectory + "/" + image
                        return try await services.ui.setPasteboardImage(file: file, device: target.device, in: &ctx)
                    default:
                        throw XcdError(.usage, "the pasteboard takes one thing", next: "pass either --text <text> or --image <file>")
                    }
                }
            }
        }

        struct GetText: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "get", abstract: "Print the device's pasteboard text, and nothing else.")
            @OptionGroup var target: DeviceOption
            @OptionGroup var options: GlobalOptions

            func run() async throws {
                try await Emit.run("sim pasteboard get", options) { services in
                    var ctx = try await services.open(worktree: options.worktree)
                    await Recording.stopOverdue(services, ctx)
                    return try await services.deviceState.pasteboard(device: target.device, in: &ctx)
                }
            }
        }
    }
}
