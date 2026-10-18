import Foundation

/// Runs `xcd <name>` when `name` isn't built in: a project command first, then a plugin.
public struct ExternalCommands: Sendable {
    public let services: Services

    public init(services: Services) { self.services = services }

    /// Returns the command's exit code. Throws `usage` with suggestions when nothing has that name.
    /// The worktree is opened (and so registered) only once something is about to run.
    public func run(_ name: String, arguments: [String], builtins: [String]) async throws -> Int32 {
        let config = try await projectConfig()
        if config?.commands?[name] != nil {
            var ctx = try await services.open(worktree: nil)
            return try await services.projectCommands.run(name, arguments: arguments, in: &ctx)
        }
        let finder = PluginFinder(environment: services.environment)
        if let plugin = finder.plugin(named: name) {
            var environment = ["XCD_OUTPUT": services.output.rawValue]
            if config != nil {
                let ctx = try await services.open(worktree: nil)
                let requested = services.environment["XCD_DEVICE"].flatMap { $0.isEmpty ? nil : $0 }
                environment = try ContextInfo.resolve(ctx: ctx, requestedDevice: requested, provisioner: services.provisioner,
                                                      output: services.output).environment
            }
            return try await PluginRunner(runner: services.runner).run(plugin, arguments: arguments, environment: environment,
                                                                       workingDirectory: services.currentDirectory)
        }
        let known = builtins + (config?.commands ?? [:]).keys.sorted() + finder.plugins().map(\.name)
        let close = Suggest.closest(to: name, in: known, limit: 3)
        throw XcdError(.usage, "'\(name)' is not an xcd command, a project command, or a plugin",
                       next: close.isEmpty
                           ? "run `xcd help` to see every command"
                           : "did you mean \(close.map { "`xcd \($0)`" }.joined(separator: ", "))? `xcd help` lists every command")
    }

    /// The current worktree's .xcdev.yml (or the main checkout's, borrowed), or nil outside a project. Reads only:
    /// unlike `Services.open`, it never initializes or registers the worktree. An invalid .xcdev.yml is still an error:
    /// it may define the command.
    func projectConfig() async throws -> XcdevConfig? {
        do {
            let location = try await WorktreeLocator(runner: services.runner).locate(from: services.currentDirectory)
            return try ConfigLoader.checkout(worktreeRoot: location.worktreeRoot, projectRoot: location.projectRoot).config
        } catch let error as XcdError where error.code == .notInProject || error.code == .configMissing {
            return nil
        }
    }
}
