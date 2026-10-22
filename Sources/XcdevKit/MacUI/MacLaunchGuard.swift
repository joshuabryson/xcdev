import Foundation

/// Another worktree's running copy of the app, which a shared launch would share the app's data with.
public struct MacLaunchBlocker: Sendable, Equatable {
    /// The folder that holds that copy's `.xcdev/`.
    public let worktreeRoot: String
    public let pid: Int32
}

/// The `app_in_use` rules: `isolation: shared` beside another worktree's running copy, and `suffix` beside
/// a worktree whose name slugs alike.
public enum MacLaunchGuard {
    /// The running copy that blocks a launch from `worktreeRoot`: one whose executable lies under another worktree's
    /// `.xcdev/` folder, the worktrees compared in canonical form. A copy outside every `.xcdev/` (the user's own, from
    /// /Applications or Xcode's DerivedData), this worktree's own, and one macOS gives no path for never block. When
    /// several block, the lowest pid is named.
    public static func blocker(among copies: [MacRunningCopy], worktreeRoot: String) -> MacLaunchBlocker? {
        let own = Paths.canonical(worktreeRoot)
        return copies.compactMap { copy -> MacLaunchBlocker? in
            guard let root = worktree(of: copy), Paths.canonical(root) != own else { return nil }
            return MacLaunchBlocker(worktreeRoot: root, pid: copy.pid)
        }.min { $0.pid < $1.pid }
    }

    /// The folder before the first `/.xcdev/` in the copy's executable path, or nil when there is none.
    static func worktree(of copy: MacRunningCopy) -> String? {
        guard let path = copy.executablePath, let range = path.range(of: "/.xcdev/") else { return nil }
        return String(path[..<range.lowerBound])
    }

    /// Refuses a shared launch of `product` while another worktree's copy of it runs.
    public static func check(product: AppProduct, device: String, in ctx: WorktreeContext, apps: any MacRunningAppsListing) throws {
        guard let blocker = blocker(of: product.bundleId, in: ctx, apps: apps) else { return }
        throw XcdError(.appInUse, running(product.bundleId, blocker) + "under isolation: shared both copies would share its data",
                       next: "ask the user, or run `xcd terminate --device \(device)` in that worktree; "
                           + "`isolation: suffix` in .xcdev.yml gives each worktree its own copy")
    }

    /// Refuses a suffix launch of this worktree's `copy` while another worktree runs its copy of the same id: worktree
    /// names that slug alike (`feature_login`, `feature-login`) give one id, so the two copies would share one container.
    public static func checkSuffix(copy: AppProduct, device: String, in ctx: WorktreeContext, apps: any MacRunningAppsListing) throws {
        guard let blocker = blocker(of: copy.bundleId, in: ctx, apps: apps) else { return }
        throw XcdError(.appInUse, running(copy.bundleId, blocker) + "both worktrees slug to `.xcd-\(MacBundleSlug.slug(ctx.state.name))`, "
                           + "so under isolation: suffix they would share its data",
                       next: "rename one worktree so its slug differs, or run `xcd terminate --device \(device)` in that worktree")
    }

    /// The running copy of `bundleId` that blocks a launch from this worktree.
    static func blocker(of bundleId: String, in ctx: WorktreeContext, apps: any MacRunningAppsListing) -> MacLaunchBlocker? {
        blocker(among: apps.copies(of: bundleId), worktreeRoot: ctx.paths.root)
    }

    /// The start of an `app_in_use` message: what runs, from where.
    static func running(_ bundleId: String, _ blocker: MacLaunchBlocker) -> String {
        "\(bundleId) is already running from the worktree at \(blocker.worktreeRoot) (pid \(blocker.pid)); "
    }
}
