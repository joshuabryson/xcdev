import ArgumentParser
import XcdevKit

struct TargetOptions: ParsableArguments {
    @Option(help: "Device name from .xcdev.yml (default: defaultDevice).", completion: .devices) var device: String?
    @Option(help: "Use this Xcode for this command only: a version, \"latest\", \"beta\", or a path. Not pinned.")
    var xcode: String?
}

struct SchemeOptions: ParsableArguments {
    @Option(help: "A key under schemes: (app, test) or a scheme name.",
            completion: .project { await $0.schemes() }) var scheme: String?
    @Option(help: "Build configuration, e.g. Debug or Release.",
            completion: .list(["Debug", "Release"])) var configuration: String?
    @Option(help: "Give up after this long, e.g. 45m (default: 30m for build and run, 60m for test).") var timeout: String?
}

struct LaunchFlags: ParsableArguments {
    @Option(help: "A launch preset from .xcdev.yml.",
            completion: .project { await $0.presets() }) var preset: String?
    @Option(help: "An environment variable for the app, KEY=VALUE. Repeatable.") var env: [String] = []
    @Option(name: .customLong("crash-window"), help: "How long to watch for a crash after launch (default: 5s).")
    var crashWindow: String?
    @Argument(parsing: .postTerminator, help: "Launch arguments for the app, after `--`, e.g. `xcd run -- -resetOnboarding YES`.")
    var args: [String] = []

    func options() throws -> LaunchOptions {
        LaunchOptions(preset: preset, arguments: args, environment: try LaunchOptions.parseEnvironment(env),
                      crashWindow: try DurationText.option(crashWindow, flag: "--crash-window") ?? .seconds(5))
    }
}
