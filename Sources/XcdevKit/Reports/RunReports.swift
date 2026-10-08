public struct RunReport: Reportable {
    public enum Status: String, Codable, Sendable {
        case running, crashed, exited
        case buildFailed = "build_failed"
    }

    public let status: Status
    public let build: BuildReport?
    public let target: String?
    public let targetSummary: String?
    public let bundleId: String?
    public let pid: Int32?
    public let appLog: String?
    public let crashWindow: Double
    /// Seconds after launch at which the process was gone.
    public let exitedAfter: Double?
    public let crash: CrashReport?
    /// The app's last output lines, when it crashed or exited.
    public let appOutput: [String]?
    public let note: String?
    public let worktree: String

    public init(status: Status, build: BuildReport?, target: String?, targetSummary: String?, bundleId: String?,
                pid: Int32?, appLog: String?, crashWindow: Double, exitedAfter: Double?, crash: CrashReport?,
                appOutput: [String]?, note: String?, worktree: String) {
        self.status = status
        self.build = build
        self.target = target
        self.targetSummary = targetSummary
        self.bundleId = bundleId
        self.pid = pid
        self.appLog = appLog
        self.crashWindow = crashWindow
        self.exitedAfter = exitedAfter
        self.crash = crash
        self.appOutput = appOutput
        self.note = note
        self.worktree = worktree
    }

    init(buildFailed build: BuildReport, worktree: String) {
        self.init(status: .buildFailed, build: build, target: build.target, targetSummary: build.targetSummary,
                  bundleId: nil, pid: nil, appLog: nil, crashWindow: 0, exitedAfter: nil, crash: nil, appOutput: nil,
                  note: nil, worktree: worktree)
    }

    public var text: String {
        if status == .buildFailed, let build { return build.text }
        var lines: [String] = []
        if let build { lines += [build.headline] + build.notes.map { "note: " + $0 } }
        let identity = "bundle=\(bundleId ?? "-") device=\(targetSummary ?? "-")  pid=\(pid.map(String.init) ?? "-")"
        let after = DurationText.format(.seconds(exitedAfter ?? 0))
        switch status {
        case .running:
            lines.append("launched \(bundleId ?? "-")  device=\(targetSummary ?? "-")  pid=\(pid.map(String.init) ?? "-")  running after \(DurationText.format(.seconds(crashWindow)))")
        case .crashed:
            lines.append("app crashed  \(identity) after \(after)")
            if let crash {
                lines.append("crash: " + [crash.exception, crash.termination].compactMap { $0 }.joined(separator: ", "))
                lines += crash.frames.map { "  " + $0 }
            }
        case .exited:
            lines.append("app exited  \(identity) after \(after) (no crash report found)")
        case .buildFailed:
            break
        }
        if let appOutput, !appOutput.isEmpty {
            lines.append("app output (last lines):")
            lines += appOutput.map { "  " + $0 }
        }
        if let crash { lines.append("report: \(crash.path)") }
        if let appLog { lines.append("app log: \(appLog)") }
        if let note { lines.append("note: \(note)") }
        return lines.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktree }

    public var failure: XcdError? {
        let after = DurationText.format(.seconds(exitedAfter ?? 0))
        switch status {
        case .running:
            return nil
        case .buildFailed:
            return XcdError(.buildFailed, build?.failure?.message ?? "build failed", next: "fix the errors and re-run `xcd run`")
        case .crashed:
            return XcdError(.appCrashed, "the app crashed \(after) after launch",
                            next: "fix the crash (see the frames, app output, and report above), then re-run `xcd run`")
        case .exited:
            return XcdError(.appCrashed, "the app exited \(after) after launch without a crash report",
                            next: "check the app's output with `xcd logs --app` and its logs with `xcd logs`, then re-run `xcd run`")
        }
    }
}

public struct AppActionReport: Reportable {
    public let action: String
    public let bundleId: String
    public let target: String
    public let note: String?
    public let worktree: String

    public var text: String {
        "\(action) \(bundleId)  device=\(target)" + (note.map { "\nnote: \($0)" } ?? "")
    }

    public var envelopeWorktree: String? { worktree }
}
