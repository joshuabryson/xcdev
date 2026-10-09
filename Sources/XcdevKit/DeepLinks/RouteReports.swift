import Foundation

/// `xcd open` with no argument: the project's routes.
public struct RouteListReport: Reportable {
    public struct Param: Codable, Sendable, Equatable {
        public let name: String
        public let description: String?
        public let required: Bool
        public let defaultValue: String?
        public let values: [String]?
        public let raw: Bool

        enum CodingKeys: String, CodingKey {
            case name, description, required, values, raw
            case defaultValue = "default"
        }
    }

    public struct Route: Codable, Sendable, Equatable {
        public let name: String
        public let description: String
        public let kind: String
        public let url: String?
        public let launch: RouteSpec.Launch?
        public let run: String?
        public let preset: String?
        public let expect: String?
        public let params: [Param]
    }

    public let routes: [Route]
    public let worktree: String
    let rows: [String]

    enum CodingKeys: String, CodingKey { case routes, worktree }

    /// Routes in name order, so related ones (`settings/…`) sit together.
    public init(config: XcdevConfig, worktree: String) {
        let sorted = config.routes.sorted { $0.key < $1.key }
        routes = sorted.map { name, spec in
            Route(name: name, description: spec.description, kind: spec.kinds.first?.rawValue ?? "", url: spec.url,
                  launch: spec.launch, run: spec.run, preset: spec.preset, expect: spec.expect,
                  params: spec.allParams.sorted { $0.key < $1.key }.map { name, param in
                      Param(name: name, description: param.description, required: param.isRequired,
                            defaultValue: param.defaultValue, values: param.values, raw: param.isRaw)
                  })
        }
        rows = sorted.flatMap { name, spec -> [String] in
            var head = [name, spec.kinds.first?.rawValue ?? ""]
            if let preset = spec.preset { head.append("preset=\(preset)") }
            return [(head + [spec.description]).joined(separator: "  ")] + RouteListing.paramRows(spec)
        }
        self.worktree = worktree
    }

    public var text: String {
        guard !routes.isEmpty else {
            return "no routes  add them under `deeplinks:` in .xcdev.yml (`xcd config explain deeplinks`)"
        }
        let count = "\(routes.count) route\(routes.count == 1 ? "" : "s")"
        return (rows + ["\(count)  open one with `xcd open <route> [name=value …]`"]).joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktree }
}

/// `xcd open <route>` or `xcd open <url>`: what was sent and what the app did, or with
/// `--dry-run` what would be sent.
public struct OpenReport: Reportable {
    public struct App: Codable, Sendable, Equatable {
        public let state: AppArrival
        public let pid: Int32?
        /// Nil for a script route in a worktree with no build: xcd does not know the app.
        public let bundleId: String?
        /// The app's captured output, when xcd started it.
        public let log: String?
    }

    public struct Check: Codable, Sendable, Equatable {
        public let target: String
        public let outcome: CheckOutcome
        public let seconds: Double?
        public let reason: String?
    }

    /// Nil for a URL given directly.
    public let route: String?
    public let kind: RouteSpec.Kind
    /// The device's name in the config, as `--device` takes it: "iphone".
    public let device: String
    /// The name with its type and OS: "iphone (iPhone 18 Pro, iOS 27.0)". Nil for a dry run, which touches no device.
    public var deviceSummary: String?
    public let dryRun: Bool
    public var url: String?
    /// For a link route on a real run: whether the link went out. False when the copy xcd started was gone before
    /// it could be sent.
    public var linkSent: Bool?
    public var arguments: [String]?
    public var environment: [String: String]?
    public var script: String?
    /// Where a script route's script wrote its output.
    public var scriptLog: String?
    /// For a dry run of a script route: the `XCD_PARAM_*` variables that would be left unset.
    public var unset: [String]?
    public var preset: String?
    public var app: App?
    public var check: Check?
    /// Why the command failed when the check did: the element did not appear, or the look could not be made.
    var checkFailure: XcdError?
    /// Seconds after delivery at which the app's process was gone.
    public var exitedAfter: Double?
    public var crash: CrashReport?
    /// The app's last output lines, when it crashed or exited and xcd had started it.
    public var appOutput: [String]?
    public var note: String?
    public let worktree: String

    enum CodingKeys: String, CodingKey {
        case route, kind, device, deviceSummary, dryRun, url, linkSent, arguments, environment, script, scriptLog, unset, preset, app,
             check, exitedAfter, crash, appOutput, note, worktree
    }

    init(_ route: ResolvedRoute, device: String, dryRun: Bool, worktree: String) {
        self.route = route.name
        kind = route.delivery.kind
        self.device = device
        self.dryRun = dryRun
        self.worktree = worktree
        preset = route.preset
        switch route.delivery {
        case .url(let link):
            url = link
        case .launch(let launchArguments, let launchEnvironment):
            arguments = launchArguments
            environment = launchEnvironment
        case .script(let command, let variables, let left):
            script = command
            environment = variables
            unset = dryRun ? left : nil
        }
    }

    public var envelopeWorktree: String? { worktree }

    /// The process ended while xcd watched it.
    var appEnded: Bool { exitedAfter != nil }

    public var text: String {
        var head = [(dryRun ? "would open " : "opened ") + (route ?? "link"), "device=\(deviceSummary ?? device)"]
        if let app {
            head.append("app=\(app.state.rawValue)")
            if let pid = app.pid { head.append("pid=\(pid)") }
        }
        var lines = [head.joined(separator: "  ")] + sentLines
        if let preset { lines.append("preset: \(preset)") }
        if let check { lines.append("check: " + Self.checkText(check)) }
        lines += endedLines
        if let note { lines.append("note: \(note)") }
        if let log = app?.log ?? scriptLog { lines.append("log: \(log)") }
        return lines.joined(separator: "\n")
    }

    /// `url:`, or `args:` and `env:`, or `script:` with `env:` and `unset:`.
    var sentLines: [String] {
        var lines: [String] = []
        if let url { lines.append("url: \(url)") }
        if let arguments, !arguments.isEmpty { lines.append("args: " + arguments.map(Shell.quote).joined(separator: " ")) }
        if let script { lines.append("script: \(script)") }
        if let environment, !environment.isEmpty {
            lines.append("env: " + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\(Shell.quote($0.value))" }.joined(separator: " "))
        }
        if let unset, !unset.isEmpty { lines.append("unset: " + unset.joined(separator: " ")) }
        return lines
    }

    var endedLines: [String] {
        guard let exitedAfter else { return [] }
        let after = DurationText.format(.seconds(exitedAfter))
        let unsent = linkSent == false ? ", before the link was sent" : ""
        var lines = [(crash == nil ? "app exited \(after) later (no crash report found)" : "app crashed \(after) later") + unsent]
        if let crash {
            lines.append("crash: " + [crash.exception, crash.termination].compactMap { $0 }.joined(separator: ", "))
            lines += crash.frames.map { "  " + $0 }
        }
        if let appOutput, !appOutput.isEmpty {
            lines.append("app output (last lines):")
            lines += appOutput.map { "  " + $0 }
        }
        if let crash { lines.append("report: \(crash.path)") }
        return lines
    }

    static func checkText(_ check: Check) -> String {
        switch check.outcome {
        case .appeared: return "\(check.target) appeared after \(DurationText.format(.seconds(check.seconds ?? 0)))"
        case .missing: return "\(check.target) did not appear within \(DurationText.format(.seconds(check.seconds ?? 0)))" + why(check)
        case .failed: return "could not run" + why(check)
        case .inconclusive, .skipped: return check.outcome.rawValue + why(check)
        }
    }

    private static func why(_ check: Check) -> String { check.reason.map { " (\($0))" } ?? "" }

    /// Takes over what the arrival check found.
    mutating func arrived(_ result: ArrivalResult) {
        check = result.check
        checkFailure = result.failure
    }

    /// What reached the device for a route of this kind, as a failure that follows it says it.
    static func sent(_ kind: RouteSpec.Kind) -> String {
        switch kind {
        case .url: return "the link was sent"
        case .launch: return "the app was started with the route's arguments"
        case .run: return "the script ran"
        }
    }

    /// A process that ended is the failure, whatever the check saw. Else the check's failure, if it has one.
    public var failure: XcdError? {
        guard let exitedAfter else { return checkFailure }
        let after = DurationText.format(.seconds(exitedAfter))
        let ended = crash == nil ? "exited \(after) later without a crash report" : "crashed \(after) later"
        let next = crash == nil ? "check the app's output with `xcd logs --app` and its logs with `xcd logs`"
                                : "fix the crash (see the frames and report above), then run `xcd open` again"
        return XcdError(.appCrashed, Self.endedText(kind, linkSent: linkSent, ended), next: next)
    }

    /// What reached the app before it ended, then how it ended. A link that never went out is not called sent.
    static func endedText(_ kind: RouteSpec.Kind, linkSent: Bool?, _ ended: String) -> String {
        if kind == .url, linkSent == false { return "xcd started the app, and it \(ended), before the link was sent" }
        return "\(sent(kind)), and the app \(ended)"
    }
}
