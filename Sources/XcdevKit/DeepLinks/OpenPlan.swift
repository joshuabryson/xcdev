public struct OpenOptions: Sendable {
    public var device: String?
    /// `--preset`: restart the app with this preset first. Replaces the route's own.
    public var preset: String?
    /// `--cold`: stop the app and let the link start it.
    public var cold: Bool
    /// `--dry-run`: say what would be sent, and send nothing.
    public var dryRun: Bool

    public init(device: String? = nil, preset: String? = nil, cold: Bool = false, dryRun: Bool = false) {
        self.device = device
        self.preset = preset
        self.cold = cold
        self.dryRun = dryRun
    }
}

/// A resolved route with the command's flags applied. Building one touches no device.
struct OpenPlan: Sendable {
    let route: ResolvedRoute
    /// `--device` as given, for errors that name the command to run.
    let requestedDevice: String?
    /// The preset in force: `--preset`, else the route's.
    let preset: String?
    /// Only a link can start the app, so `--cold` changes nothing for a launch route.
    let cold: Bool
    /// How the app is started when xcd starts it: the preset's arguments and environment, then a launch route's.
    let launch: LaunchPlan

    init(_ route: ResolvedRoute, _ options: OpenOptions, onMac: Bool, config: XcdevConfig) throws {
        let kind = route.delivery.kind
        for (flag, given) in [("--preset", options.preset != nil), ("--cold", options.cold)] where given && kind == .run {
            throw XcdError(.usage, "\(flag) does not apply to a script route: its script starts the app itself",
                           next: "run `xcd open \(route.name ?? "")` without \(flag)")
        }
        self.route = route
        requestedDevice = options.device
        preset = options.preset ?? route.preset
        cold = options.cold && kind == .url
        if cold, let preset, !onMac {
            throw XcdError(.usage, "--cold cannot be combined with the preset '\(preset)' on a simulator: the system starts the app, so launch arguments cannot be passed",
                           next: options.preset == nil ? "run it without --cold: this route has a preset" : "drop --cold or --preset")
        }
        var start = LaunchOptions(preset: preset, crashWindow: CrashWindows.started)
        if case .launch(let arguments, let environment) = route.delivery {
            start.arguments = arguments
            start.environment = environment
        }
        launch = try start.plan(config: config)
    }

    /// The report so far: what is sent, and to which device. A launch route shows its preset's arguments too.
    func report(device: String, dryRun: Bool, worktree: String) -> OpenReport {
        var report = OpenReport(route, device: device, dryRun: dryRun, worktree: worktree)
        report.preset = preset
        if case .launch = route.delivery {
            report.arguments = launch.arguments
            report.environment = launch.environment
        }
        return report
    }
}

/// How long the app is watched after a delivery.
enum CrashWindows {
    /// The link went to a copy that was already running.
    static let running: Duration = .seconds(2)
    /// xcd, or the link, started the app: the launch crash window.
    static let started: Duration = .seconds(5)
}
