import Foundation

extension UIService {
    /// `xcd ui menu [path]`: lists the menu bar, or presses the item the path names.
    public func menu(_ path: String?, _ options: UIOptions, in ctx: inout WorktreeContext) async throws -> UIMenuReport {
        guard let mac = try await macSession(options, in: ctx) else {
            throw XcdError(.platformUnsupported, "a simulator has no menu bar; `xcd ui menu` is for Mac apps",
                           next: "use `xcd ui tap` on the app's own buttons, or pass --device with a Mac device")
        }
        let menu = MacMenu(api: mac.api, app: mac.api.application(pid: mac.pid))
        guard let path else { return UIMenuReport(device: mac.device, items: try menu.items(), pressed: nil, tree: nil, worktree: ctx.state.name) }
        var report = UIMenuReport(device: mac.device, items: nil, pressed: try menu.press(path: path).path, tree: nil, worktree: ctx.state.name)
        guard options.tree else { return report }
        // The press has happened: a tree that cannot be read is said, as after any action, not made the command's failure.
        let request = TreeRequest(bundleId: try bundleId(options, in: ctx), system: false, all: false)
        let result: Result<TreeResult, RunnerFailure> = try mac.perform(RunnerProtocol.treePath, request)
        if case .success(let tree) = result { report.tree = tree } else { report.notes = [UIText.treeUnreadNote] }
        return report
    }
}
