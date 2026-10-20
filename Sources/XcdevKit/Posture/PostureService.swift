import Foundation

/// `xcd sim fold` and, on a foldable, `xcd ui rotate`. For now, the direct route only.
public struct PostureService: Sendable {
    public let provisioner: DeviceProvisioner
    public let recipes: PostureRecipeStore
    public let routes: [any PostureRoute]
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void

    public init(provisioner: DeviceProvisioner, globalPaths: GlobalPaths, routes: [any PostureRoute] = [],
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.provisioner = provisioner
        recipes = PostureRecipeStore(globalPaths: globalPaths)
        self.routes = routes
        self.now = now
        self.sleep = sleep
    }

    /// A booted foldable clone and what a report says about it.
    struct Target: Sendable {
        var name: String
        var clone: ProvisionedDevice
        var worktree: String
        var recipes: PostureRecipes

        func report(_ state: PostureState, route: PostureRouteID?, verified: Bool, already: Bool) -> PostureReport {
            PostureReport(device: name, udid: clone.udid, posture: state.postureText, angle: state.degrees,
                          display: state.display, orientation: state.orientation?.rawValue, route: route?.rawValue,
                          verified: verified, already: already, worktree: worktree)
        }
    }

    /// Whether `device`'s clone has a hinge; the clone is made if it does not exist yet, as every sim command does.
    public func isFoldable(device: String?, in ctx: inout WorktreeContext) async throws -> Bool {
        let name = try provisioner.deviceName(device, config: ctx.config)
        let clone = try await provisioner.ensure(name, in: &ctx)
        return try recipes.load().isFoldable(deviceTypeIdentifier: clone.deviceTypeIdentifier)
    }

    /// `xcd sim fold`: reports the posture, or sets it and waits for the witness.
    public func fold(_ options: FoldOptions, in ctx: inout WorktreeContext) async throws -> PostureReport {
        let target = try await foldable(options.device, in: &ctx)
        let before = try await reader(for: ctx).state(udid: target.clone.udid)
        guard let request = options.request else { return target.report(before, route: nil, verified: true, already: false) }
        if before.satisfies(request) { return target.report(before, route: nil, verified: true, already: true) }
        throw XcdError(.internalError, "applying a posture is not available yet", next: "wait for it")
    }

    /// Boots `device`'s clone and checks it has a hinge; `platform_unsupported` otherwise.
    func foldable(_ device: String?, in ctx: inout WorktreeContext) async throws -> Target {
        let name = try provisioner.deviceName(device, config: ctx.config)
        let recipes = try recipes.load()
        let (clone, _) = try await provisioner.boot(name, in: &ctx)
        guard recipes.isFoldable(deviceTypeIdentifier: clone.deviceTypeIdentifier) else {
            let foldables = ctx.state.devices.filter { recipes.isFoldable(deviceTypeIdentifier: $0.value.deviceTypeIdentifier) }
            let names = foldables.keys.sorted()
            throw XcdError(.platformUnsupported, "device '\(name)' (\(clone.deviceType)) has no hinge",
                           next: names.isEmpty
                               ? "add a foldable under `devices:` in .xcdev.yml, e.g. `duo: { type: \"iPhone Duo\", runtime: \"27.1\" }`"
                               : "pass --device \(names.joined(separator: "|"))")
        }
        return Target(name: name, clone: clone, worktree: ctx.state.name, recipes: recipes)
    }

    func reader(for ctx: WorktreeContext) -> PostureReader {
        PostureReader(runner: provisioner.runner, developerDir: ctx.xcode?.developerDir, now: now, sleep: sleep)
    }
}
