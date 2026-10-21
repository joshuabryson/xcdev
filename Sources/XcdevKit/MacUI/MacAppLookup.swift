import Foundation

/// The running process of this worktree's build of a Mac app, by executable path.
public enum MacAppLookup {
    /// The one error for a Mac device with no build record, wherever it is found first (a `ui` command's bundle id,
    /// or the app's process): `--system` has no meaning on a Mac, so only a build or `--bundle` names the app.
    public static func notBuilt(_ device: String) -> XcdError {
        XcdError(.appNotBuilt, "no app has been built for \(device) in this worktree",
                 next: "build and start it with `xcd run --device \(device)` first, or name a running app with `--bundle <id>`")
    }

    public static func runningPid(device: String, runner: any ProcessRunning, in ctx: WorktreeContext) async throws -> Int32 {
        guard let product = try AppStateStore.load(ctx.paths).builds[device]?.product else { throw notBuilt(device) }
        guard let pid = try await ProcessLookup(runner: runner).pids(of: product.executablePath).max() else {
            throw XcdError(.elementNotFound, "the app is not running on this Mac",
                           next: "start it with `xcd run --device \(device)` (or `xcd launch --device \(device)`), then retry")
        }
        return pid
    }
}
