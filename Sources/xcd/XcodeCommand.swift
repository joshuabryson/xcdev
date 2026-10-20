import ArgumentParser
import XcdevKit

struct XcodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode",
        abstract: "Open the project in Xcode, for a person to work in.",
        discussion: """
        Opens the .xcworkspace, .xcodeproj, or Package.swift that `project:` names in .xcdev.yml, with the Xcode this \
        worktree uses (its pin, or `--xcode` for this command only). A worktree with no pin yet gets one first, from \
        `xcode:` in the config, as `xcd build` does. Nothing is built. Every worktree has its own copy of the \
        project, so run it in the worktree whose code you want to see.
        """)
    @Option(help: "Use this Xcode for this command only. Not pinned.") var xcode: String?
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("xcode", options) { services in
            var ctx = try await services.open(worktree: options.worktree, xcode: xcode)
            return try await services.xcodeOpener.open(in: &ctx)
        }
    }
}
