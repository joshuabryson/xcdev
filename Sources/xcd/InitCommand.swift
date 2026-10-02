import ArgumentParser
import XcdevKit

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create .xcdev.yml for this project without prompting. Start with --plan (see `xcd guide setup`).",
        discussion: "--plan prints the decisions to make and writes nothing. --set applies answers and recommends the rest; --defaults (or no flag) takes every recommendation.")
    @Flag(help: "Detect the project and print the decisions to ask the user. Writes nothing.") var plan = false
    @Flag(help: "Write the config using every recommendation (the default).") var defaults = false
    @Option(name: .customLong("set"), parsing: .upToNextOption,
            help: "Answers as KEY=VALUE, e.g. --set devices.default=\"iPhone 17 Pro\" xcode=system. Repeatable.")
    var answers: [String] = []
    @Flag(help: "Replace an existing .xcdev.yml.") var force = false
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        if plan {
            guard answers.isEmpty, !defaults, !force else {
                throw ValidationError("--plan writes nothing, so it can't be combined with --set, --defaults, or --force")
            }
            try await Emit.run("init", options) { services in try await services.setup.plan(from: services.currentDirectory) }
        } else {
            try await Emit.run("init", options) { services in
                try await services.setup.write(answers: try InitAnswers.parse(answers), force: force,
                                               from: services.currentDirectory)
            }
        }
    }
}
