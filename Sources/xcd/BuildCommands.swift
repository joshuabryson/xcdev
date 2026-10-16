import ArgumentParser
import XcdevKit

struct BuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build the app scheme for a device, using this worktree's own build folder.")
    @OptionGroup var target: TargetOptions
    @OptionGroup var scheme: SchemeOptions
    @Flag(help: "Clean before building.") var clean = false
    @Flag(help: "List every warning, not only those in the files you changed.") var warnings = false
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("build", options) { services in
            var ctx = try await services.open(worktree: options.worktree, xcode: target.xcode)
            let timeout = try DurationText.option(scheme.timeout, flag: "--timeout") ?? .seconds(1800)
            return try await services.builds.buildNotingSetup(
                BuildOptions(device: target.device, scheme: scheme.scheme, configuration: scheme.configuration,
                             clean: clean, showWarnings: warnings, timeout: timeout),
                in: &ctx)
        }
    }
}

struct TestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run the test scheme on a device and report failures with file and line.")
    @OptionGroup var target: TargetOptions
    @OptionGroup var scheme: SchemeOptions
    @Option(help: "Run only this test, class, or target, e.g. AppTests/LoginTests or AppTests/works(). Repeatable.")
    var only: [String] = []
    @Option(help: "Skip this test, class, or target. Repeatable.") var skip: [String] = []
    @Flag(help: "List every warning, not only those in the files you changed.") var warnings = false
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("test", options) { services in
            var ctx = try await services.open(worktree: options.worktree, xcode: target.xcode)
            await Recording.stopOverdue(services, ctx)
            let timeout = try DurationText.option(scheme.timeout, flag: "--timeout") ?? .seconds(3600)
            return try await services.tests.test(
                TestOptions(device: target.device, scheme: scheme.scheme, configuration: scheme.configuration,
                            only: only, skip: skip, timeout: timeout, showWarnings: warnings),
                in: &ctx)
        }
    }
}

struct CleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Clean this worktree's build products (--deep deletes its whole DerivedData folder).")
    @Option(help: "A key under schemes: (app, test) or a scheme name.") var scheme: String?
    @Option(help: "Use this Xcode for this command only. Not pinned.") var xcode: String?
    @Flag(help: "Delete .xcdev/DerivedData entirely instead of running xcodebuild clean.") var deep = false
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("clean", options) { services in
            var ctx = try await services.open(worktree: options.worktree, xcode: xcode)
            return try await services.builds.clean(scheme: scheme, deep: deep, in: &ctx)
        }
    }
}
