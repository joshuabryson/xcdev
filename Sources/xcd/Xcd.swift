import ArgumentParser
import XcdevKit

@main
struct Xcd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcd",
        abstract: "One entry point for agents doing Apple-platform development.",
        version: XcdevVersion.current
    )
}
