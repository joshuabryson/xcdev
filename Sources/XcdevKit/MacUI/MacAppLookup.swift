import Foundation

/// The running process of this worktree's build of a Mac app, by executable path.
public enum MacAppLookup {
    public static func runningPid(device: String, runner: any ProcessRunning, in ctx: WorktreeContext) async throws -> Int32 {
        guard let product = try AppStateStore.load(ctx.paths).builds[device]?.product else {
            throw XcdError(.appNotBuilt, "no app has been built for \(device) in this worktree",
                           next: "build and start it with `xcd run --device \(device)`")
        }
        guard let pid = try await ProcessLookup(runner: runner).pids(of: product.executablePath).max() else {
            throw XcdError(.elementNotFound, "the app is not running on this Mac",
                           next: "start it with `xcd run --device \(device)` (or `xcd launch --device \(device)`), then retry")
        }
        return pid
    }
}
