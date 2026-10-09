import Foundation

/// Runs a script route: the project's own way to reach a screen.
struct RouteScript: Sendable {
    let runner: any ProcessRunning
    let progress: @Sendable (String) -> Void
    let now: @Sendable () -> Date

    /// Runs the route's command with `/bin/sh -c` from the worktree root, the way hooks run. Its environment is the
    /// context contract plus `XCD_ROUTE` and one `XCD_PARAM_<NAME>` per parameter that has a value. Its output goes
    /// to a new `<yyyyMMdd-HHmmss>-route-<name>.log` under `logs`, which is returned. A non-zero exit is
    /// `route_failed`, and running past the route's timeout is `timeout`.
    func run(_ route: ResolvedRoute, context: ContextInfo, logs: WorktreePaths) async throws -> String {
        guard case .script(let command, let variables, _) = route.delivery else {
            throw XcdError(.internalError, "\(route.name ?? "a link") is not a script route")
        }
        let name = route.name ?? ""
        // A route's name can hold `/`; a file's name cannot.
        let log = logs.newArtifact(in: logs.logs, kind: "route-" + name.replacingOccurrences(of: "/", with: "-"), ext: "log", now: now())
        progress("running the script of route '\(name)': \(command)  log: \(log)")
        let invocation = Invocation("/bin/sh", ["-c", command], environment: context.environment.merging(variables) { $1 },
                                    workingDirectory: context.worktree, timeout: route.timeout, outputFile: log)
        let result: ProcessOutput
        do {
            result = try await runner.run(invocation)
        } catch var error as XcdError where error.code == .timeout {
            error.message = "the script of route '\(name)' was stopped after \(DurationText.format(route.timeout))"
            error.details = ["script: \(command)", "log: \(log)"]
            error.next = "raise deeplinks.routes.\(name).timeout in .xcdev.yml, or make the script faster"
            throw error
        }
        guard result.succeeded else { throw Self.failed(name, command, exitCode: result.exitCode, log: log) }
        return log
    }

    /// The script ran and exited non-zero: `route_failed`, with the last 20 lines of its log. 126 and 127 are the
    /// shell's "not executable" and "not found".
    static func failed(_ name: String, _ command: String, exitCode: Int32, log: String) -> XcdError {
        let tail = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).suffix(20)
        let again = "then run `xcd open \(name)` again"
        let next: String
        switch exitCode {
        case 127:
            next = "the script's command was not found; fix deeplinks.routes.\(name).run in .xcdev.yml (paths are relative to the worktree root), \(again)"
        case 126:
            next = "the script is not executable; run `chmod +x` on it, \(again)"
        default:
            next = "fix the script (its output is in the log), \(again)"
        }
        return XcdError(.routeFailed, "the script of route '\(name)' ran and exited \(exitCode)", next: next,
                        details: ["script: \(command)", "log: \(log)"] + tail)
    }
}
