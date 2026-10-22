import Foundation

public enum AppEnvironment {
    /// Makes `print` output reach the log file as it happens, and mirrors os_log/Logger lines to stderr.
    public static let captureOutput = ["NSUnbufferedIO": "YES", "OS_ACTIVITY_DT_MODE": "YES"]
}

/// Where an app is installed and run: a simulator clone, or this Mac.
public protocol AppHost: Sendable {
    func install(_ product: AppProduct) async throws
    func uninstall(_ product: AppProduct) async throws
    /// Starts the app with stdout and stderr going to `logFile`; returns its pid, or nil when the launch went
    /// through but no process was ever seen (it may have crashed before it could be).
    func launch(_ product: AppProduct, arguments: [String], environment: [String: String], logFile: String) async throws -> Int32?
    /// Stops the app; false when it wasn't running.
    func terminate(_ product: AppProduct) async throws -> Bool
    /// The pid of the app's running process, however it was started, or nil when it is not running. On a simulator,
    /// an app that is not installed is `simulator_failed`.
    func runningPid(_ product: AppProduct) async throws -> Int32?
    /// Sends a link to the app.
    func open(_ url: String, in product: AppProduct) async throws
    /// A host whose `launch` starts the app with `url` as the link it is started for, or nil where only the system
    /// can start an app for a link (a simulator: stop the app and send the link with `open`).
    func launching(with url: String) -> (any AppHost)?
}

/// Finds running processes by the path of their executable.
struct ProcessLookup: Sendable {
    let runner: any ProcessRunning

    /// Pids whose executable is `path`.
    func pids(of path: String) async throws -> Set<Int32> {
        try await pids(of: [path])[path] ?? []
    }

    /// Pids whose executable is one of `paths`, by the path as given, from one listing; a path with none has no entry.
    /// `ps -o comm` prints the full executable path on macOS. Paths are compared in canonical form, so a link or a
    /// `/private` prefix in either one does not hide a match. `ps` answers in a twentieth of a second, but on a
    /// saturated Mac it has taken over ten, so it gets thirty.
    func pids(of paths: [String]) async throws -> [String: Set<Int32>] {
        let out = try await runner.runChecked(Invocation("/bin/ps", ["-axo", "pid=,comm="], timeout: .seconds(30)))
        let wanted = Dictionary(paths.map { (Paths.canonical($0), $0) }) { first, _ in first }
        let names = Set(paths.map { ($0 as NSString).lastPathComponent })
        var pids: [String: Set<Int32>] = [:]
        for line in out.stdoutString.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
            let command = String(trimmed[trimmed.index(after: space)...])
            // Most processes are something else: compare names before resolving a path.
            guard names.contains(where: { command.hasSuffix($0) }), let path = wanted[Paths.canonical(command)] else { continue }
            pids[path, default: []].insert(pid)
        }
        return pids
    }
}

public struct SimulatorAppHost: AppHost {
    public let simctl: SimctlClient
    public let udid: String

    public init(simctl: SimctlClient, udid: String) {
        self.simctl = simctl
        self.udid = udid
    }

    public func install(_ product: AppProduct) async throws {
        try await simctl.install(udid: udid, appPath: product.path)
    }

    public func uninstall(_ product: AppProduct) async throws {
        try await simctl.uninstall(udid: udid, bundleId: product.bundleId)
    }

    public func launch(_ product: AppProduct, arguments: [String], environment: [String: String],
                       logFile: String) async throws -> Int32? {
        try await simctl.launch(udid: udid, bundleId: product.bundleId, arguments: arguments, environment: environment,
                                logFile: logFile)
    }

    public func terminate(_ product: AppProduct) async throws -> Bool {
        try await simctl.terminate(udid: udid, bundleId: product.bundleId)
    }

    /// A simulator app is a process on this Mac, running from where the simulator installed it.
    public func runningPid(_ product: AppProduct) async throws -> Int32? {
        guard let container = try await simctl.appContainer(udid: udid, bundleId: product.bundleId) else {
            throw XcdError(.simulatorFailed, "\(product.bundleId) is not installed on this simulator",
                           next: "install and start it with `xcd run`")
        }
        return try await ProcessLookup(runner: simctl.runner).pids(of: container + "/" + product.executableName).max()
    }

    /// Approves the link's own scheme first, so no "Open in …?" alert holds it. An http or
    /// https link goes through the system like a tapped one and needs no approval.
    public func open(_ url: String, in product: AppProduct) async throws {
        if let scheme = LinkScheme.of(url), !LinkScheme.isWeb(scheme) {
            try await simctl.approveScheme(udid: udid, scheme: scheme, bundleId: product.bundleId)
        }
        try await simctl.openURL(udid: udid, url: url)
    }

    public func launching(with url: String) -> (any AppHost)? { nil }
}

/// Runs a macOS app straight from this worktree's DerivedData. Nothing is installed.
public struct MacAppHost: AppHost {
    public let runner: any ProcessRunning
    let sleep: @Sendable (Duration) async throws -> Void
    /// The link `launch` starts the app with: a cold start.
    private(set) var link: String?
    /// Start visible and in front, for a person. Every other launch is hidden.
    private(set) var show = false
    /// Keeps a hidden app from being napped between commands.
    static let appNapArguments = ["-NSAppSleepDisabled", "YES"]

    public init(runner: any ProcessRunning,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.runner = runner
        self.sleep = sleep
    }

    public func showing(_ show: Bool) -> MacAppHost {
        var host = self
        host.show = show
        return host
    }

    static func withAppNapOff(_ arguments: [String]) -> [String] {
        arguments.contains(appNapArguments[0]) ? arguments : appNapArguments + arguments
    }

    public func install(_ product: AppProduct) async throws {}
    public func uninstall(_ product: AppProduct) async throws {}

    public func launch(_ product: AppProduct, arguments: [String], environment: [String: String],
                       logFile: String) async throws -> Int32? {
        let before = try await lookup.pids(of: product.executablePath)
        var args = ["-n"] + (show ? [] : ["-g", "-j"]) + ["--stdout", logFile, "--stderr", logFile]
        if show { Notes.current?.add("shown and brought to the front at your request") }
        let env = AppEnvironment.captureOutput.merging(environment, uniquingKeysWith: { $1 })
        for (key, value) in env.sorted(by: { $0.key < $1.key }) { args += ["--env", "\(key)=\(value)"] }
        // With a link, the app is named by `-a` and the link is what `open` opens with it.
        args += link.map { ["-a", product.path, $0] } ?? [product.path]
        let arguments = show ? arguments : Self.withAppNapOff(arguments)      // a shown launch adds nothing
        if !arguments.isEmpty { args += ["--args"] + arguments }
        try await runner.runChecked(Invocation("/usr/bin/open", args), next: "read the app log: \(logFile)")
        for _ in 0..<20 {
            if let pid = try await lookup.pids(of: product.executablePath).subtracting(before).max() { return pid }
            try await sleep(.milliseconds(250))
        }
        return nil
    }

    public func terminate(_ product: AppProduct) async throws -> Bool {
        try await !terminate([product]).isEmpty
    }

    /// Stops every process running from one of `products`, found in one look at the process list: the products that
    /// had one, in the order given. Each process is asked to stop (SIGTERM) and not waited for.
    func terminate(_ products: [AppProduct]) async throws -> [AppProduct] {
        let running = try await lookup.pids(of: products.map(\.executablePath))
        for pid in running.values.reduce(into: Set<Int32>(), { $0.formUnion($1) }).sorted() {
            _ = try await runner.run(Invocation("/bin/kill", ["-TERM", String(pid)]))
        }
        return products.filter { running[$0.executablePath] != nil }
    }

    public func runningPid(_ product: AppProduct) async throws -> Int32? {
        try await lookup.pids(of: product.executablePath).max()
    }

    /// The link goes to the copy at this build's path, also when another worktree's copy of the app is running,
    /// and `-g` keeps it in the background.
    public func open(_ url: String, in product: AppProduct) async throws {
        try await runner.runChecked(Invocation("/usr/bin/open", ["-g", "-a", product.path, url]),
                                    next: "check that the app is still at \(product.path) (`xcd build` puts it there), then retry")
    }

    public func launching(with url: String) -> (any AppHost)? {
        var host = self
        host.link = url
        return host
    }

    var lookup: ProcessLookup { ProcessLookup(runner: runner) }
}
