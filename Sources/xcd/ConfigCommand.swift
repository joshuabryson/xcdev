import ArgumentParser
import XcdevKit

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Inspect the project configuration (.xcdev.yml).",
        subcommands: [Show.self, Schema.self, Explain.self]
    )

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the merged config (.xcdev.yml + .xcdev.local.yml) and this worktree's pinned values.")
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("config show", options) { services in
                let ctx = try await services.open(worktree: options.worktree)
                return ConfigReport(config: ctx.config, worktree: ctx.state)
            }
        }
    }

    struct Explain: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Explain a .xcdev.yml key: what it does, allowed values, default, and an example. No key lists them all.")
        @Argument(help: "A key path such as devices.iphone.runtime or hooks.pre-build.") var key: String?
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("config explain", options) { _ in try ConfigExplainReport(key: key) }
        }
    }

    struct Schema: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the JSON Schema for .xcdev.yml.")

        func run() throws {
            print(JSONSchemaWriter.write())
        }
    }
}
