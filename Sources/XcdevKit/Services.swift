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
    /// The SIGINT/SIGTERM handler's state: cleanups to run, and whether output must stop.
    public let interrupts: Interrupts
    /// Launches processes that outlive the command (screen recordings), and stops them again.
    public let detached: any DetachedProcessLaunching
    /// Carries requests to a clone's UI runner over loopback HTTP.
    public let runnerTransport: any RunnerTransport

    public init(runner: any ProcessRunning, globalPaths: GlobalPaths, currentDirectory: String,
                environment: [String: String], progress: @escaping @Sendable (String) -> Void = { _ in },
                terminal: (@Sendable (String) -> Void)? = nil, output: OutputFormat? = nil, interrupts: Interrupts = .shared,
                detached: any DetachedProcessLaunching = SystemDetachedProcesses(),
                runnerTransport: any RunnerTransport = URLSessionRunnerTransport()) {
        self.runner = runner
        self.globalPaths = globalPaths
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.progress = progress
        self.terminal = terminal
        self.output = output ?? OutputFormat.resolve(jsonFlag: false, environment: environment)
        self.interrupts = interrupts
        self.detached = detached
        self.runnerTransport = runnerTransport
    }

    /// Progress stops once Ctrl-C has fired the handler: what follows would only describe the stopped children.
    public static func live() -> Services {
        let environment = ProcessInfo.processInfo.environment
        let interrupts = Interrupts.shared
        let stderr: @Sendable (String) -> Void = { StandardError.write($0) }
        let interactive = Activity.animates(stderrIsTerminal: isatty(STDERR_FILENO) == 1, environment: environment, output: .text)
        return Services(runner: SystemProcessRunner(interrupts: interrupts), globalPaths: .live(environment: environment),
                        currentDirectory: FileManager.default.currentDirectoryPath, environment: environment,
                        progress: { line in interrupts.perform { stderr("xcd: \(line)\n") } },
                        terminal: interactive ? stderr : nil, interrupts: interrupts,
                        detached: SystemDetachedProcesses(inheritedEnvironment: environment))
    }

    /// Long steps: a spinner on a terminal, unless the output is JSON; otherwise `progress` lines.
    public var activity: Activity {
        if let terminal, output != .json {
            return .animated(write: terminal, columns: Activity.stderrColumns, interrupts: interrupts)
        }
        return .plain(progress)
    }

    public var worktrees: WorktreeService { WorktreeService(runner: runner, globalPaths: globalPaths, hooks: hooks, detached: detached) }
    public var provisioner: DeviceProvisioner { DeviceProvisioner(runner: runner, globalPaths: globalPaths) }
    public var media: MediaService { MediaService(provisioner: provisioner, detached: detached, currentDirectory: currentDirectory) }
    public var runnerBuilder: RunnerBuilder { RunnerBuilder(runner: runner, globalPaths: globalPaths, progress: progress) }
    public var runners: RunnerSupervisor {
        RunnerSupervisor(provisioner: provisioner, builder: runnerBuilder, detached: detached,
                         client: RunnerClient(transport: runnerTransport), globalPaths: globalPaths)
    }
    public var ui: UIService { UIService(supervisor: runners, client: RunnerClient(transport: runnerTransport)) }
    public var deviceState: DeviceStateService { DeviceStateService(provisioner: provisioner) }
    public var hooks: HookRunner { HookRunner(runner: runner, output: output, progress: progress) }
    public var builds: BuildService { BuildService(runner: runner, provisioner: provisioner, progress: progress, hooks: hooks) }
    public var tests: TestService { TestService(builds: builds, detached: detached) }
    public var apps: RunService {
        RunService(builds: builds, watcher: CrashWatcher(probe: SystemProcessProbe(), locator: CrashReportLocator()))
    }
    public var routes: RouteService { RouteService(apps: apps, arrival: ui, output: output) }
    public var projectCommands: ProjectCommandRunner {
        ProjectCommandRunner(builds: builds, output: output, environment: environment)
    }
    public var setup: InitService {
        var service = InitService(runner: runner, globalPaths: globalPaths, progress: activity, interrupts: interrupts)
        service.locator = ToolLocator(environment: environment)
        return service
    }
    public var doctor: DoctorService { DoctorService(runner: runner, globalPaths: globalPaths, detached: detached,
                                                      runnerClient: RunnerClient(transport: runnerTransport)) }
    /// What `xcd lint` and `xcd format` run with.
    public var quality: QualityHost {
        QualityHost(runner: runner, locator: ToolLocator(environment: environment), currentDirectory: currentDirectory,
                    interrupts: interrupts, output: output)
    }
    public var lint: LintService { LintService(quality) }
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
