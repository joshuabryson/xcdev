import Foundation

/// Runs the hooks configured under `hooks:` in .xcdev.yml.
public struct HookRunner: Sendable {
    public let runner: any ProcessRunning
    /// Passed to the hook as XCD_OUTPUT.
    public let output: OutputFormat
    public let progress: @Sendable (String) -> Void
    public let timeout: Duration
    public let now: @Sendable () -> Date

    public init(runner: any ProcessRunning, output: OutputFormat = .text,
                progress: @escaping @Sendable (String) -> Void = { _ in }, timeout: Duration = .seconds(1800),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.output = output
        self.progress = progress
        self.timeout = timeout
        self.now = now
    }

    /// Runs `hook` for this worktree, with the context of `device` (a config device name, or nil). `product`, when
    /// given, is the app the context names instead of the build: the product a launch started.
    /// Returns the hook's log, or nil when the hook isn't configured.
    @discardableResult
    public func run(_ hook: HookName, in ctx: WorktreeContext, device: String?, product: AppProduct? = nil) async throws -> String? {
        let context = ContextInfo.build(ctx: ctx, device: device, output: output).with(product: product)
        return try await run(hook, config: ctx.config, context: context, logs: ctx.paths)
    }

    /// Runs `hook` from `config` with `/bin/sh -c`, from `context.worktree`, with the context contract and
    /// `XCD_HOOK=<name>` in its environment and its output in a new `<yyyyMMdd-HHmmss>-hook-<name>.log` under `logs`. A
    /// non-zero exit throws `hook_failed`. Returns the log, or nil when the hook isn't configured.
    @discardableResult
    public func run(_ hook: HookName, config: XcdevConfig, context: ContextInfo, logs: WorktreePaths) async throws -> String? {
        guard let command = config.hooks?.command(for: hook), !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        let log = logs.newArtifact(in: logs.logs, kind: "hook-" + hook.rawValue, ext: "log", now: now())
        progress("running the \(hook.rawValue) hook: \(command)  log: \(log)")
        let invocation = Invocation("/bin/sh", ["-c", command], environment: context.environment.merging(["XCD_HOOK": hook.rawValue]) { $1 },
                                    workingDirectory: context.worktree, timeout: timeout, outputFile: log)
        let result: ProcessOutput
        do {
            result = try await runner.run(invocation)
        } catch var error as XcdError where error.code == .timeout {
            error.message = "the \(hook.rawValue) hook timed out after \(DurationText.format(timeout))"
            error.details = ["hook: \(command)", "log: \(log)"]
            error.next = "make hooks.\(hook.rawValue) in .xcdev.yml finish sooner, then re-run"
            throw error
        }
        guard result.succeeded else {
            let tail = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init).suffix(20)
            throw XcdError(.hookFailed, "the \(hook.rawValue) hook failed (exit \(result.exitCode))",
                           next: Self.next(for: hook, exitCode: result.exitCode),
                           details: ["hook: \(command)", "log: \(log)"] + tail)
        }
        return log
    }

    /// 126 and 127 are the shell's "not executable" and "not found".
    static func next(for hook: HookName, exitCode: Int32) -> String {
        let key = "hooks.\(hook.rawValue)"
        switch exitCode {
        case 127: return "the hook's command was not found; fix \(key) in .xcdev.yml (paths are relative to the worktree root), then re-run"
        case 126: return "the hook's script is not executable; run `chmod +x` on it, then re-run"
        default: return "fix the hook (its output is in the log), or remove \(key) from .xcdev.yml, then re-run"
        }
    }
}
