import ArgumentParser
import XcdevKit

struct GuideCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guide",
        abstract: "Print a Markdown guide written for agents (e.g. `xcd guide setup`). No topic lists them.")
    @Argument(help: "The guide to print.") var topic: String?
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("guide", options) { _ in try GuideReport(topic: topic) }
    }
}
