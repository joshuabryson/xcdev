import Foundation

/// Live wiring shared by the CLI (and the future MCP server).
public struct Services: Sendable {
    public let runner: any ProcessRunning
    public let globalPaths: GlobalPaths
    public let currentDirectory: String
    public let environment: [String: String]
    /// One-line progress messages for long operations. The CLI writes them to stderr.
    public let progress: @Sendable (String) -> Void
    /// Raw writes to stderr for animated progress, set only when stderr is a terminal that isn't dumb.
    public let terminal: (@Sendable (String) -> Void)?
    /// The output format of this invocation, passed to extensions as XCD_OUTPUT. The CLI sets it from --json.
    public var output: OutputFormat

    public init(runner: any ProcessRunning, globalPaths: GlobalPaths, currentDirectory: String,
                environment: [String: String], progress: @escaping @Sendable (String) -> Void = { _ in },
                terminal: (@Sendable (String) -> Void)? = nil, output: OutputFormat? = nil) {
        self.runner = runner
        self.globalPaths = globalPaths
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.progress = progress
        self.terminal = terminal
        self.output = output ?? OutputFormat.resolve(jsonFlag: false, environment: environment)
    }

    public static func live() -> Services {
        let environment = ProcessInfo.processInfo.environment
        let stderr: @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
        let interactive = Activity.animates(stderrIsTerminal: isatty(STDERR_FILENO) == 1, environment: environment, output: .text)
        return Services(runner: SystemProcessRunner(), globalPaths: .live(environment: environment),
                        currentDirectory: FileManager.default.currentDirectoryPath, environment: environment,
                        progress: { stderr("xcd: \($0)\n") }, terminal: interactive ? stderr : nil)
    }

    /// Long steps: a spinner on a terminal, unless the output is JSON; otherwise `progress` lines.
    public var activity: Activity {
        if let terminal, output != .json { return .animated(write: terminal, columns: Activity.stderrColumns) }
        return .plain(progress)
    }

    public var worktrees: WorktreeService { WorktreeService(runner: runner, globalPaths: globalPaths, hooks: hooks) }
    public var provisioner: DeviceProvisioner { DeviceProvisioner(runner: runner, globalPaths: globalPaths) }
    public var hooks: HookRunner { HookRunner(runner: runner, output: output, progress: progress) }
    public var builds: BuildService { BuildService(runner: runner, provisioner: provisioner, progress: progress, hooks: hooks) }
    public var tests: TestService { TestService(builds: builds) }
    public var apps: RunService {
        RunService(builds: builds, watcher: CrashWatcher(probe: SystemProcessProbe(), locator: CrashReportLocator()))
    }
    public var projectCommands: ProjectCommandRunner {
        ProjectCommandRunner(builds: builds, output: output, environment: environment)
    }
    public var setup: InitService { InitService(runner: runner, globalPaths: globalPaths, progress: activity) }
    public var doctor: DoctorService { DoctorService(runner: runner, globalPaths: globalPaths) }
    public var externalCommands: ExternalCommands { ExternalCommands(services: self) }
    public var help: HelpService { HelpService(services: self) }
    public var logs: LogService { LogService(runner: runner, provisioner: provisioner) }

    /// Opens the worktree; `xcode` is a one-off `--xcode` override that is never pinned.
    public func open(worktree: String?, xcode: String? = nil) async throws -> WorktreeContext {
        var ctx = try await worktrees.open(from: currentDirectory, worktreeName: worktree)
        if let xcode { ctx.xcodeOverride = try await XcodeDiscovery(runner: runner).resolve(spec: xcode) }
        return ctx
    }
}
