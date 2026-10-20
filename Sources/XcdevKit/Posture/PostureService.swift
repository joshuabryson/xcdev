import Foundation

/// `xcd sim fold` and, on a foldable, `xcd ui rotate`. For now, the direct route only.
public struct PostureService: Sendable {
    public let provisioner: DeviceProvisioner
    public let recipes: PostureRecipeStore
    public let routes: [any PostureRoute]
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void

    public init(provisioner: DeviceProvisioner, globalPaths: GlobalPaths, routes: [any PostureRoute] = [VendorEventRoute()],
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
        let verdict = try await deliver(request, to: target, route: options.route, in: ctx)
        return target.report(verdict.state, route: .direct, verified: verdict.verified, already: false)
    }

    /// `xcd ui rotate` on a foldable: the pose pipeline instead of the runner, which the Duo ignores.
    public func rotate(_ orientation: String, _ options: UIOptions, in ctx: inout WorktreeContext) async throws -> UIActionReport {
        guard let wanted = DeviceOrientation(rawValue: orientation) else {
            throw XcdError(.usage, "'\(orientation)' is not an orientation",
                           next: "use one of: " + DeviceOrientation.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let started = now()
        let target = try await foldable(options.device, in: &ctx)
        let recipe = try context(for: target, in: ctx).recipe
        guard recipe.supports(wanted) else { throw recipe.unsupported(wanted) }
        let before = try await reader(for: ctx).state(udid: target.clone.udid)
        let request = PostureRequest.orientation(wanted)
        let already = before.satisfies(request)
        let verdict = already ? PostureVerdict(state: before, verified: true)
                              : try await deliver(request, to: target, route: nil, in: ctx)
        var report = UIActionReport(action: "rotated to", target: orientation, element: nil, x: nil, y: nil,
                                    ms: Int(now().timeIntervalSince(started) * 1000), restarted: false,
                                    device: target.name, udid: target.clone.udid, worktree: target.worktree)
        report.notes = Self.rotationNotes(verdict, already: already)
        return report
    }

    static func rotationNotes(_ verdict: PostureVerdict, already: Bool) -> [String] {
        var notes = ["via the pose pipeline (foldable): posture \(verdict.state.postureText), display \(verdict.state.display)"]
        if already { notes.append("already in that orientation; nothing sent") }
        if !verdict.verified { notes.append("unverified: devicectl did not report the orientation within 5 s") }
        return notes
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

    /// Sends through the chosen route and waits for the witness while the route holds its connection.
    func deliver(_ request: PostureRequest, to target: Target, route wanted: PostureRouteID?,
                 in ctx: WorktreeContext) async throws -> PostureVerdict {
        let context = try context(for: target, in: ctx)
        let route = try await pick(wanted, context)
        let reader = reader(for: ctx)
        let sentAt = now()
        do {
            return try await route.apply(request, context) {
                try await reader.waitForWitness(request, udid: context.udid, since: sentAt)
            }
        } catch let error as VendorEventError {
            throw XcdError(.postureFailed, "the \(route.id.rawValue) route failed at \(error.step)",
                           next: "run `xcd sim fold` to see the posture, then `xcd doctor`", details: [error.detail])
        }
    }

    /// The clone, the Xcode, and the recipe entry for them.
    func context(for target: Target, in ctx: WorktreeContext) throws -> PostureContext {
        guard let xcode = ctx.xcode else {
            throw XcdError(.internalError, "no Xcode is resolved for this worktree", next: "run `xcd doctor`")
        }
        let runtimeVersion = target.clone.runtime.split(separator: " ").last.map(String.init) ?? ""
        guard let recipe = PostureRecipeStore.direct(in: target.recipes, xcode: xcode, runtimeVersion: runtimeVersion) else {
            throw XcdError(.postureFailed, "no posture recipe matches Xcode \(xcode.version) (\(xcode.build)) and \(target.clone.runtime)",
                           next: "add a `direct` entry for them to \(recipes.overridePath)")
        }
        return PostureContext(udid: target.clone.udid, developerDir: xcode.developerDir, recipe: recipe)
    }

    /// The route asked for, or the first available one. For now there is the direct route only.
    func pick(_ wanted: PostureRouteID?, _ context: PostureContext) async throws -> any PostureRoute {
        var reasons: [String] = []
        for route in routes where wanted == nil || route.id == wanted {
            switch await route.availability(context) {
            case .available: return route
            case .unavailable(let reason): reasons.append("\(route.id.rawValue): \(reason)")
            }
        }
        throw XcdError(.postureFailed, "no route can reach the simulator's pose pipeline", next: "run `xcd doctor`", details: reasons)
    }
}
