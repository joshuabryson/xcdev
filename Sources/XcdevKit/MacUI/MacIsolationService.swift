import Foundation

/// A Mac device's data isolation: which product a command reads, what a launch does first, and what the
/// launch's report notes. `shared` runs the build itself and refuses a launch beside another worktree's running copy;
/// `suffix` runs this worktree's re-signed copy, which has its own container and preferences.
public struct MacIsolationService: Sendable {
    public let copier: MacIsolatedCopy
    public let runningApps: any MacRunningAppsListing

    public init(runner: any ProcessRunning, reader: any MacBundleReading = SystemBundleReader(),
                runningApps: any MacRunningAppsListing = SystemRunningApps()) {
        copier = MacIsolatedCopy(runner: runner, reader: reader)
        self.runningApps = runningApps
    }

    /// The device's `isolation`; `shared` when the key is missing or the device is unknown.
    public static func mode(of device: String, in ctx: WorktreeContext) -> IsolationMode {
        (ctx.config.allDevices[device] ?? DeviceSpec()).isolationMode
    }

    /// The product every command reads for `device`: the build itself, or under `suffix` this worktree's copy of a Mac
    /// app. It follows from the build, the worktree's name, and the config alone, so a rebuild or
    /// a config change never leaves it stale, and it names the copy before a launch has made it.
    public static func product(_ built: AppProduct, device: String, in ctx: WorktreeContext) -> AppProduct {
        guard built.isMac, mode(of: device, in: ctx) == .suffix else { return built }
        return built.isolated(worktreeName: ctx.state.name, in: ctx.paths)
    }

    /// What a Mac launch's report notes: the copy that runs with its own data under `suffix`, else what every
    /// worktree's build of the app shares.
    public static func note(for built: AppProduct, device: String, in ctx: WorktreeContext) -> String {
        guard mode(of: device, in: ctx) == .suffix else { return RunReport.sharedData(of: built.bundleId) }
        return "isolation: \(product(built, device: device, in: ctx).bundleId)"
    }

    /// Under suffix: make or refresh the copy (a refused product copies nothing), then refuse app_in_use while another
    /// worktree whose name slugs alike runs its copy of the same id; return the copy. Under shared: refuse app_in_use,
    /// return `built`. `RunService.begin` calls it once this worktree's running processes have been asked to stop
    /// (SIGTERM, not awaited); the copy is replaced by rename, so a process still exiting keeps its unlinked files.
    public func prepareLaunch(built: AppProduct, device: String, in ctx: WorktreeContext) async throws -> AppProduct {
        guard built.isMac else { return built }
        switch Self.mode(of: device, in: ctx) {
        case .suffix:
            let copy = Self.product(built, device: device, in: ctx)
            _ = try await copier.refresh(source: built, copy: copy, device: device)
            try MacLaunchGuard.checkSuffix(copy: copy, device: device, in: ctx, apps: runningApps)
            return copy
        case .sharedData:
            try MacLaunchGuard.check(product: built, device: device, in: ctx, apps: runningApps)
            return built
        }
    }
}
