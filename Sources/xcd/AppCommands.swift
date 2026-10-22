import ArgumentParser
import XcdevKit

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build, install, and launch the app, then watch for a crash.",
        discussion: "App launch arguments go after `--`: xcd run --preset onboarding -- -resetOnboarding YES. On a Mac device with `isolation: suffix`, the app runs as a re-signed copy with its own data; see `xcd config explain devices.<name>.isolation`.")
    @OptionGroup var target: TargetOptions
    @OptionGroup var scheme: SchemeOptions
    @Flag(name: .customLong("no-build"), help: "Launch the latest build without building first.") var noBuild = false
    @OptionGroup var launch: LaunchFlags
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("run", options) { services in
            var ctx = try await services.open(worktree: options.worktree, xcode: target.xcode)
            await Recording.stopOverdue(services, ctx)
            let timeout = try DurationText.option(scheme.timeout, flag: "--timeout") ?? .seconds(1800)
            return try await services.apps.run(
                BuildOptions(device: target.device, scheme: scheme.scheme, configuration: scheme.configuration, timeout: timeout),
                noBuild: noBuild, launch: try launch.options(), in: &ctx)
        }
    }
}

struct LaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch the installed app (no build or install), then watch for a crash.",
        discussion: "App launch arguments go after `--`: xcd launch -- -resetOnboarding YES. On a Mac device with `isolation: suffix`, the app runs as a re-signed copy with its own data; see `xcd config explain devices.<name>.isolation`.")
    @OptionGroup var target: TargetOptions
    @OptionGroup var launch: LaunchFlags
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("launch", options) { services in
            var ctx = try await services.open(worktree: options.worktree, xcode: target.xcode)
            await Recording.stopOverdue(services, ctx)
            return try await services.apps.launch(device: target.device, options: try launch.options(), in: &ctx)
        }
    }
}

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "Install the latest build on the device's clone (booting it if needed).")
    @OptionGroup var target: TargetOptions
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("install", options) { services in
            var ctx = try await services.open(worktree: options.worktree, xcode: target.xcode)
            return try await services.apps.install(device: target.device, in: &ctx)
        }
    }
}

struct UninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall", abstract: "Remove the app (and its data) from the device's clone.")
    @OptionGroup var target: TargetOptions
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("uninstall", options) { services in
            var ctx = try await services.open(worktree: options.worktree, xcode: target.xcode)
            return try await services.apps.uninstall(device: target.device, in: &ctx)
        }
    }
}

struct TerminateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminate", abstract: "Stop the running app on the device (no-op if it isn't running).")
    @OptionGroup var target: TargetOptions
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("terminate", options) { services in
            var ctx = try await services.open(worktree: options.worktree, xcode: target.xcode)
            return try await services.apps.terminate(device: target.device, in: &ctx)
        }
    }
}
