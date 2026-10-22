import Foundation

/// Another worktree's running copy of the app, which a shared launch would share the app's data with.
public struct MacLaunchBlocker: Sendable, Equatable {
    /// The folder that holds that copy's `.xcdev/`.
    public let worktreeRoot: String
    public let pid: Int32
}

/// The `app_in_use` rule of `isolation: shared`.
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
        guard let blocker = blocker(among: apps.copies(of: product.bundleId), worktreeRoot: ctx.paths.root) else { return }
        throw XcdError(.appInUse, "\(product.bundleId) is already running from the worktree at \(blocker.worktreeRoot) "
                           + "(pid \(blocker.pid)); under isolation: shared both copies would share its data",
                       next: "ask the user, or run `xcd terminate --device \(device)` in that worktree; "
                           + "`isolation: suffix` in .xcdev.yml gives each worktree its own copy")
    }
}
