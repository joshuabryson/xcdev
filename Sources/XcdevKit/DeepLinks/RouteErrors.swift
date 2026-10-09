enum RouteErrors {
    /// Refuses a link whose own scheme the built app does not register: no real link could reach the app that way.
    /// http and https links are not checked, and neither is an app whose Info.plist cannot be read.
    static func checkScheme(_ url: String, registeredBy product: AppProduct) throws {
        guard let scheme = LinkScheme.of(url), !LinkScheme.isWeb(scheme),
              let registered = AppSchemes.registered(by: product), !AppSchemes.registers(scheme, in: registered) else { return }
        let known = registered.isEmpty
            ? "the built app registers no URL scheme (CFBundleURLTypes in its Info.plist): add one and rebuild"
            : "it registers: \(registered.joined(separator: ", "))"
        throw XcdError(.usage, "\(product.bundleId) does not register the scheme '\(scheme)'",
                       next: known + "; for a link meant for another app, use `xcd sim open-url`")
    }

    /// A `--cold` link after which no process of the app appeared.
    static func notStarted(_ url: String, _ product: AppProduct) -> XcdError {
        var next = "check that the app handles the link when it is not running, and read its log with `xcd logs`"
        if let scheme = LinkScheme.of(url), LinkScheme.isWeb(scheme) {
            next += "; an https link opens in Safari unless the app's associated domains work on this simulator"
        }
        return XcdError(.routeFailed, "the link was sent, but it did not start \(product.bundleId) within 30s", next: next,
                        details: ["url: \(url)"])
    }

    /// Script routes come later.
    static func scriptsNotYet(_ route: ResolvedRoute) -> XcdError {
        var command = ""
        if case .script(let run, _, _) = route.delivery { command = run }
        let name = route.name ?? ""
        return XcdError(.usage, "route '\(name)' runs a script, which this version of xcd cannot do yet",
                        next: "run it yourself from the worktree root: \(command)  (`xcd open \(name) --dry-run` shows the variables it expects)")
    }
}
