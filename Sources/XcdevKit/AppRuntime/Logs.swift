import Foundation

public enum LogLevel: String, Sendable, CaseIterable {
    case `default`, info, debug
}

public struct LogOptions: Sendable {
    public var device: String?
    public var since: Duration
    public var level: LogLevel
    /// Case-insensitive text the message must contain.
    public var grep: String?
    /// Stream for this long instead of showing past entries.
    public var follow: Duration?
    /// Include Apple framework messages (com.apple.* subsystems).
    public var includeSystem: Bool
    public var limit: Int
    /// Show the latest launch's captured stdout/stderr instead of the unified log.
    public var appOutput: Bool

    public init(device: String? = nil, since: Duration = .seconds(120), level: LogLevel = .info, grep: String? = nil,
                follow: Duration? = nil, includeSystem: Bool = false, limit: Int = 200, appOutput: Bool = false) {
        self.device = device
        self.since = since
        self.level = level
        self.grep = grep
        self.follow = follow
        self.includeSystem = includeSystem
        self.limit = limit
        self.appOutput = appOutput
    }
}

public struct LogEntry: Codable, Sendable, Equatable {
    public let timestamp: String
    /// messageType: Default, Info, Debug, Error, or Fault.
    public let type: String
    public let subsystem: String?
    public let category: String?
    public let pid: Int32?
    public let message: String

    /// "12:55:23.213 Info [dev.xcdev.SampleApp:app] sample log line"
    public var text: String {
        let time = timestamp.count >= 23 ? String(timestamp.dropFirst(11).prefix(12)) : timestamp
        var tag = ""
        if let subsystem, !subsystem.isEmpty {
            tag = " [" + subsystem + ((category ?? "").isEmpty ? "" : ":" + category!) + "]"
        }
        return "\(time) \(type)\(tag) " + message.replacingOccurrences(of: "\n", with: "\n    ")
    }
}

public enum LogParser {
    /// `log show|stream --style ndjson`: one JSON object per line. Skips the "Filtering…" banner,
    /// the `{"count":…,"finished":…}` trailer, and non-log events such as activities.
    public static func parse(_ ndjson: String) -> [LogEntry] {
        struct Raw: Decodable {
            let timestamp: String?
            let eventType: String?
            let messageType: String?
            let subsystem: String?
            let category: String?
            let processID: Int32?
            let eventMessage: String?
        }
        let decoder = JSONDecoder()
        return ndjson.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("{"), let raw = try? decoder.decode(Raw.self, from: Data(line.utf8)),
                  raw.eventType == "logEvent", let timestamp = raw.timestamp, let message = raw.eventMessage else { return nil }
            return LogEntry(timestamp: timestamp, type: raw.messageType ?? "Default", subsystem: raw.subsystem,
                            category: raw.category, pid: raw.processID, message: message)
        }
    }
}

public enum LogQuery {
    /// The app's own messages; Apple framework subsystems only with `includeSystem`.
    public static func predicate(processName: String, includeSystem: Bool) -> String {
        let escaped = processName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = "process == \"\(escaped)\""
        return includeSystem ? process : process + " AND NOT (subsystem BEGINSWITH \"com.apple.\")"
    }

    /// Arguments after `log`: `show` for the recent past, or `stream` with its own `--timeout` when following.
    public static func arguments(_ options: LogOptions, processName: String) -> [String] {
        let predicate = predicate(processName: processName, includeSystem: options.includeSystem)
        if let follow = options.follow {
            let seconds = Int(DurationText.seconds(follow).rounded(.up))
            return ["stream", "--style", "ndjson", "--level", options.level.rawValue, "--timeout", String(seconds),
                    "--predicate", predicate]
        }
        let seconds = Int(DurationText.seconds(options.since).rounded(.up))
        var args = ["show", "--style", "ndjson", "--last", "\(seconds)s", "--predicate", predicate]
        if options.level != .default { args.append("--info") }
        if options.level == .debug { args.append("--debug") }
        return args
    }
}

public struct LogService: Sendable {
    public let runner: any ProcessRunning
    public let provisioner: DeviceProvisioner
    public let now: @Sendable () -> Date

    public init(runner: any ProcessRunning, provisioner: DeviceProvisioner,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.provisioner = provisioner
        self.now = now
    }

    public func logs(_ options: LogOptions, in ctx: inout WorktreeContext) async throws -> LogsReport {
        if let follow = options.follow, follow > ctx.config.maxLogFollow {
            throw XcdError(.usage, "--for \(DurationText.format(follow)) is longer than logs.maxFollow (\(DurationText.format(ctx.config.maxLogFollow)))",
                           next: "use a shorter --for, or raise logs.maxFollow in .xcdev.yml")
        }
        let container = try ProjectContainer.resolve(config: ctx.config, worktreeRoot: ctx.location.worktreeRoot)
        let target = try provisioner.targetName(options.device, container: container, config: ctx.config)
        if options.appOutput { return try appOutput(options, target: target, in: ctx) }

        let product = try RunService.product(for: target, requested: options.device, in: ctx)
        let args = LogQuery.arguments(options, processName: product.executableName)
        var invocation: Invocation
        if product.isMac {
            invocation = Invocation("/usr/bin/log", args, timeout: .seconds(120))
        } else {
            guard let clone = ctx.state.devices[target] else {
                throw XcdError(.appNotBuilt, "\(target) has no simulator clone in this worktree yet",
                               next: "run `xcd run --device \(target)` first")
            }
            invocation = .xcrun(["simctl", "spawn", clone.udid, "log"] + args, developerDir: ctx.xcode?.developerDir,
                                timeout: .seconds(120))
        }
        var captureFile: String?
        if let follow = options.follow {
            let file = ctx.paths.newArtifact(in: ctx.paths.logs, kind: "stream", ext: "log", now: now())
            invocation.outputFile = file
            invocation.stopAtTimeout = true
            invocation.timeout = follow + .seconds(15)
            captureFile = file
        }
        var output = try await runner.run(invocation)
        // A follow writes stdout and stderr to the file (a pipe could outlive the stop); read both back.
        if let captureFile { output.stdout = (try? Data(contentsOf: URL(fileURLWithPath: captureFile))) ?? Data() }
        // Stopping `log stream` at the follow deadline is how a follow ends, not a failure.
        if !output.succeeded && !output.stoppedAtDeadline {
            if captureFile != nil { output.stderr = output.stdout }
            if output.stderrString.contains("current state: Shutdown") {
                throw XcdError(.simulatorFailed, "\(target)'s simulator is shut down, so its log can't be read",
                               next: "boot it with `xcd sim boot --device \(target)` (earlier entries are kept)")
            }
            throw XcdError.subprocess(invocation, output, next: "run `xcd doctor`")
        }
        var entries = LogParser.parse(output.stdoutString)
        if let grep = options.grep { entries = entries.filter { $0.message.localizedCaseInsensitiveContains(grep) } }
        let window = options.follow.map { "followed \(DurationText.format($0))" } ?? "last \(DurationText.format(options.since))"
        return LogsReport(source: .unifiedLog, entries: Array(entries.suffix(options.limit)), lines: [], total: entries.count,
                          processName: product.executableName, target: target, window: window, file: captureFile,
                          worktree: ctx.state.name)
    }

    private func appOutput(_ options: LogOptions, target: String, in ctx: WorktreeContext) throws -> LogsReport {
        guard let launch = try AppStateStore.load(ctx.paths).lastLaunch,
              options.device == nil || launch.target == target else {
            throw XcdError(.appNotBuilt, "nothing has been launched in this worktree yet",
                           next: "run `xcd run` (or `xcd launch`), then `xcd logs --app`")
        }
        let text = (try? String(contentsOfFile: launch.appLog, encoding: .utf8)) ?? ""
        var lines = text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let grep = options.grep { lines = lines.filter { $0.localizedCaseInsensitiveContains(grep) } }
        return LogsReport(source: .appOutput, entries: [], lines: Array(lines.suffix(options.limit)), total: lines.count,
                          processName: launch.processName, target: launch.target, window: "latest launch",
                          file: launch.appLog, worktree: ctx.state.name)
    }
}

extension LogOptions {
    /// From `xcd logs` flags. `--follow` streams for `--for`, or by default for 30s but never longer than
    /// `maxFollow` (logs.maxFollow). An explicit `--for` is kept as given; LogService rejects one over the cap.
    /// `--for` without `--follow` is a mistake.
    public static func commandLine(device: String?, since: String, level: String, grep: String?, follow: Bool,
                                   duration: String?, system: Bool, limit: Int, app: Bool,
                                   maxFollow: Duration = .seconds(300)) throws -> LogOptions {
        guard let sinceDuration = try DurationText.option(since, flag: "--since") else {
            throw XcdError(.usage, "--since needs a value", next: "use a duration like 30s, 5m, or 1h")
        }
        guard let logLevel = LogLevel(rawValue: level) else {
            throw XcdError(.usage, "--level \(level) is not one of: default, info, debug", next: "pass --level info or --level debug")
        }
        if let duration, !follow {
            throw XcdError(.usage, "--for only applies with --follow", next: "pass --follow --for \(duration)")
        }
        guard limit >= 1 else { throw XcdError(.usage, "--limit must be at least 1", next: "pass --limit 200") }
        let followFor = follow ? (try DurationText.option(duration, flag: "--for") ?? min(.seconds(30), maxFollow)) : nil
        return LogOptions(device: device, since: sinceDuration, level: logLevel, grep: grep, follow: followFor,
                          includeSystem: system, limit: limit, appOutput: app)
    }
}
