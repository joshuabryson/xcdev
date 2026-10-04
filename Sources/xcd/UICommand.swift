import ArgumentParser
import XcdevKit

struct UICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "See the simulator: screenshots and screen recordings.",
        discussion: "Captures go to ui.media.dir (default .xcdev-media/<worktree>/<branch> in the main checkout); each prints its path.",
        subcommands: [Screenshot.self, Record.self]
    )

    struct Screenshot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save a PNG of the device's screen and print its path, size, and scale.")
        @OptionGroup var target: SimCommand.DeviceOption
        @Option(help: "Write here instead of the media folder (must not exist).") var out: String?
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("ui screenshot", options) { services in
                var ctx = try await services.open(worktree: options.worktree)
                await Recording.stopOverdue(services, ctx)
                return try await services.media.screenshot(device: target.device, out: out, in: &ctx)
            }
        }
    }

    struct Record: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Record the device's screen to an MP4: start, then stop.",
                                                        subcommands: [Start.self, Stop.self])

        struct Start: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Start recording in the background and return.")
            @OptionGroup var target: SimCommand.DeviceOption
            @Option(help: "Write here instead of the media folder (must not exist).") var out: String?
            @OptionGroup var options: GlobalOptions

            func run() async throws {
                try await Emit.run("ui record start", options) { services in
                    var ctx = try await services.open(worktree: options.worktree)
                    await Recording.stopOverdue(services, ctx)
                    return try await services.media.startRecording(device: target.device, out: out, in: &ctx)
                }
            }
        }

        struct Stop: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Stop the recording, finish the file, and print its path.")
            @OptionGroup var target: SimCommand.DeviceOption
            @OptionGroup var options: GlobalOptions

            func run() async throws {
                try await Emit.run("ui record stop", options) { services in
                    let ctx = try await services.open(worktree: options.worktree)
                    return try await services.media.stopRecording(device: target.device, in: ctx)
                }
            }
        }
    }
}
