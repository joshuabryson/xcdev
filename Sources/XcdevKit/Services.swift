import Foundation

/// Live wiring shared by the CLI (and the future MCP server).
public struct Services: Sendable {
    public let runner: any ProcessRunning
    public let globalPaths: GlobalPaths
    public let currentDirectory: String
    public let environment: [String: String]

    public init(runner: any ProcessRunning, globalPaths: GlobalPaths, currentDirectory: String,
                environment: [String: String]) {
        self.runner = runner
        self.globalPaths = globalPaths
        self.currentDirectory = currentDirectory
        self.environment = environment
    }

    public static func live() -> Services {
        let environment = ProcessInfo.processInfo.environment
        return Services(runner: SystemProcessRunner(), globalPaths: .live(environment: environment),
                        currentDirectory: FileManager.default.currentDirectoryPath, environment: environment)
    }

    public var worktrees: WorktreeService { WorktreeService(runner: runner, globalPaths: globalPaths) }
    public var provisioner: DeviceProvisioner { DeviceProvisioner(runner: runner, globalPaths: globalPaths) }

    /// Opens the worktree; `xcode` is a one-off `--xcode` override that is never pinned.
    public func open(worktree: String?, xcode: String? = nil) async throws -> WorktreeContext {
        var ctx = try await worktrees.open(from: currentDirectory, worktreeName: worktree)
        if let xcode { ctx.xcodeOverride = try await XcodeDiscovery(runner: runner).resolve(spec: xcode) }
        return ctx
    }
}
