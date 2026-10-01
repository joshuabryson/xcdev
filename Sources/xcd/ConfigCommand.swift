import ArgumentParser
import XcdevKit

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Inspect the project configuration (.xcdev.yml).",
        subcommands: [Show.self, Schema.self]
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

    struct Schema: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the JSON Schema for .xcdev.yml.")

        func run() throws {
            print(JSONSchemaWriter.write())
        }
    }
}
