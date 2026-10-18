import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct ExternalCommandTests {
    static let config = WorktreeServiceTests.config + """

    commands:
      seed: { description: "Load fixture data", run: ./scripts/seed.sh, needs: [device] }
      fmt: { run: swift-format }
    """
    let fake = FakeProcessRunner()
    let builtins = ["build", "test", "run", "worktree", "config"]

    /// A project, a PATH directory holding `xcd-<name>` plugins, and services that run git for real.
    func setup(plugins: [String]) throws -> (TempProject, String) {
        let project = try TempProject.make(config: Self.config)
        let bin = project.base + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for name in plugins {
            FileManager.default.createFile(atPath: bin + "/xcd-" + name, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
        }
        return (project, bin)
    }

    func services(_ project: TempProject, bin: String, in directory: String? = nil) -> Services {
        Services(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                 currentDirectory: directory ?? project.root, environment: ["PATH": bin], output: .text)
    }

    @Test func routesHelpBuiltinsAndEverythingElse() {
        let names: Set<String> = ["build", "wt", "worktree", "help"]
        #expect(CommandRoute.route([], builtins: names) == .help(topic: [], json: false))
        #expect(CommandRoute.route(["help", "wt", "create", "--json"], builtins: names) == .help(topic: ["wt", "create"], json: true))
        #expect(CommandRoute.route(["--version"], builtins: names) == .builtin)
        #expect(CommandRoute.route(["wt", "list"], builtins: names) == .builtin)
        #expect(CommandRoute.route(["seed", "--json", "a b"], builtins: names) == .external(name: "seed", arguments: ["--json", "a b"]))
    }

    @Test func aProjectCommandWinsOverAPluginWithTheSameName() async throws {
        let (project, bin) = try setup(plugins: ["seed"])
        defer { project.remove() }
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        fake.stub(["sh"], exitCode: 6)
        let code = try await services(project, bin: bin).externalCommands.run("seed", arguments: ["x"], builtins: builtins)
        #expect(code == 6)
        #expect(fake.calls.contains { $0.argv.first == "sh" && $0.arguments.last == "x" })
        #expect(!fake.calls.contains { $0.argv.first == "xcd-seed" })
    }

    @Test func aPluginRunsWithTheWorktreeContext() async throws {
        let (project, bin) = try setup(plugins: ["lint"])
        defer { project.remove() }
        fake.stub(["xcd-lint"], exitCode: 0)
        let code = try await services(project, bin: bin).externalCommands.run("lint", arguments: ["--fix"], builtins: builtins)
        #expect(code == 0)
        let call = try #require(fake.calls.first { $0.argv.first == "xcd-lint" })
        #expect(call.executable == bin + "/xcd-lint" && call.arguments == ["--fix"] && call.passthrough)
        #expect(call.environment["XCD_WORKTREE_NAME"] == "main" && call.environment["XCD_DEVICE"] == "iphone")
        #expect(call.environment["XCD_OUTPUT"] == "text")
    }

    @Test func pluginsRunOutsideAProjectToo() async throws {
        let (project, bin) = try setup(plugins: ["lint"])
        defer { project.remove() }
        let outside = project.base + "/elsewhere"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        fake.stub(["xcd-lint"], exitCode: 0)
        _ = try await services(project, bin: bin, in: outside).externalCommands.run("lint", arguments: [], builtins: builtins)
        let call = try #require(fake.calls.first { $0.argv.first == "xcd-lint" })
        #expect(call.environment == ["XCD_OUTPUT": "text"] && call.workingDirectory == outside)
    }

    @Test func anUnknownNameSuggestsTheClosestCommands() async throws {
        let (project, bin) = try setup(plugins: ["lint"])
        defer { project.remove() }
        let error = await #expect(throws: XcdError.self) {
            try await services(project, bin: bin).externalCommands.run("sed", arguments: [], builtins: builtins)
        }
        #expect(error?.code == .usage)
        #expect(error?.message == "'sed' is not an xcd command, a project command, or a plugin")
        #expect(error?.next == "did you mean `xcd seed`? `xcd help` lists every command")
    }

    @Test func anInvalidConfigIsReportedRatherThanGuessed() async throws {
        let (project, bin) = try setup(plugins: ["seed"])
        defer { project.remove() }
        try project.write("version: 1\nproject: App.xcodeproj\ncommands:\n  seed: { needs: [device] }\n", to: ".xcdev.yml")
        let error = await #expect(throws: XcdError.self) {
            try await services(project, bin: bin).externalCommands.run("seed", arguments: [], builtins: builtins)
        }
        #expect(error?.code == .configInvalid)
    }

    @Test func helpListsProjectCommandsAndReachablePlugins() async throws {
        let (project, bin) = try setup(plugins: ["lint", "build", "seed"])
        defer { project.remove() }
        fake.stub(["xcd-lint", "--xcd-describe"], stdout: "Lint the project\n")
        let info = [BuiltinCommandInfo(name: "build", aliases: [], summary: "Build the app."),
                    BuiltinCommandInfo(name: "worktree", aliases: ["wt"], summary: "Manage worktrees.")]
        let report = await services(project, bin: bin).help.overview(builtins: info)
        #expect(report.projectCommands.map(\.name) == ["fmt", "seed"])
        #expect(report.plugins.map(\.name) == ["lint"])          // xcd-build and xcd-seed are shadowed
        #expect(report.note == nil)
        #expect(report.text.contains("\n  worktree    (alias: wt) Manage worktrees.\n"))
        #expect(report.text.contains("\n  seed        Load fixture data  needs=device\n"))
        #expect(report.text.contains("\n  lint        Lint the project  \(bin)/xcd-lint\n"))
        #expect(report.text.hasSuffix("guides: start, deeplinks, quality, setup, ui"))
    }

    @Test func helpDetailForAProjectCommandAndAnUnknownName() async throws {
        let (project, bin) = try setup(plugins: [])
        defer { project.remove() }
        let detail = try await services(project, bin: bin).help.detail("seed", builtins: builtins)
        #expect(detail.kind == "project command")
        #expect(detail.text == """
        xcd seed [args…]  (project command from .xcdev.yml)
        Load fixture data
        runs: ./scripts/seed.sh "$@"  (from the worktree root, with the XCD_* context variables)
        needs: device
        timeout: 30m00s
        """)
        let error = await #expect(throws: XcdError.self) {
            try await services(project, bin: bin).help.detail("erors", builtins: builtins)
        }
        #expect(error?.next == "did you mean `xcd help errors`?")
    }

    /// Help shows the command as xcd runs it: a `run` written as a YAML block ends in a newline, which is dropped.
    @Test func helpDetailShowsABlockRunAsItIsRun() async throws {
        let config = WorktreeServiceTests.config + "\ncommands:\n  check:\n    run: |\n      ./scripts/check.sh\n"
        let project = try TempProject.make(config: config)
        defer { project.remove() }
        let detail = try await services(project, bin: project.base + "/bin").help.detail("check", builtins: builtins)
        #expect(detail.text.contains("\nruns: ./scripts/check.sh \"$@\"  (from the worktree root"))
    }

    /// Bare `xcd` lists plugins by name only: it never runs one. `xcd help` asks them to describe themselves.
    @Test func theBareListingRunsNoPlugin() async throws {
        let (project, bin) = try setup(plugins: [])
        defer { project.remove() }
        let marker = project.base + "/ran"
        FileManager.default.createFile(atPath: bin + "/xcd-mark", contents: Data("#!/bin/sh\ntouch '\(marker)'\necho Marks\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let services = Services(runner: RoutingRunner(fake: fake, realExecutables: ["git", "xcd-mark"]),
                                globalPaths: GlobalPaths(base: project.home), currentDirectory: project.root,
                                environment: ["PATH": bin], output: .text)
        let bare = await services.help.overview(builtins: [], describePlugins: false)
        #expect(bare.plugins == [HelpReport.PluginEntry(name: "mark", path: bin + "/xcd-mark", summary: nil)])
        #expect(bare.text.contains("\n  mark        \(bin)/xcd-mark\n"))
        #expect(!FileManager.default.fileExists(atPath: marker))
        let full = await services.help.overview(builtins: [])
        #expect(full.plugins.first?.summary == "Marks")
        #expect(FileManager.default.fileExists(atPath: marker))      // the control: describing does run it
    }

    /// Help reads .xcdev.yml without opening the worktree: no worktree.json, no registry entry, nothing written.
    @Test func helpWritesNothing() async throws {
        let (project, bin) = try setup(plugins: ["lint"])
        defer { project.remove() }
        fake.stub(["xcd-lint", "--xcd-describe"], stdout: "Lint the project\n")
        let services = services(project, bin: bin)
        let before = try FileManager.default.subpathsOfDirectory(atPath: project.base).sorted()
        let report = await services.help.overview(builtins: [])
        #expect(report.projectCommands.map(\.name) == ["fmt", "seed"])
        _ = try await services.help.detail("seed", builtins: builtins)
        _ = try await services.help.detail("lint", builtins: builtins)
        _ = try? await services.help.detail("nope", builtins: builtins)
        _ = try? await services.externalCommands.run("nope", arguments: [], builtins: builtins)
        let after = try FileManager.default.subpathsOfDirectory(atPath: project.base).sorted()
        #expect(after == before)
        #expect(!FileManager.default.fileExists(atPath: WorktreePaths(root: project.root).stateFile))
        #expect(!FileManager.default.fileExists(atPath: GlobalPaths(base: project.home).registryFile))
    }
}
