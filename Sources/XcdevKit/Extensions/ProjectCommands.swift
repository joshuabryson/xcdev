import Foundation

/// Runs a command from `commands:` in .xcdev.yml as `xcd <name> [args…]`.
public struct ProjectCommandRunner: Sendable {
    public let builds: BuildService
    /// Passed to the command as XCD_OUTPUT.
    public let output: OutputFormat
    /// xcd's own environment; `XCD_DEVICE` there picks the device instead of defaultDevice.
    public let environment: [String: String]

    public init(builds: BuildService, output: OutputFormat = .text, environment: [String: String] = [:]) {
        self.builds = builds
        self.output = output
        self.environment = environment
    }

    /// Prepares what the command `needs`, then runs `/bin/sh -c '<run> "$@"' xcd-<name> <arguments…>` from the
    /// worktree root, sharing xcd's stdin, stdout, and stderr. Returns the command's exit code.
    public func run(_ name: String, arguments: [String], in ctx: inout WorktreeContext) async throws -> Int32 {
        guard let spec = ctx.config.commands?[name] else {
            throw XcdError(.usage, "no command named '\(name)' under commands: in .xcdev.yml", next: "run `xcd help` to see every command")
        }
        let requested = environment["XCD_DEVICE"].flatMap { $0.isEmpty ? nil : $0 }
        var device: String?
        if spec.needsDevice {
            let name = try deviceForCommand(name, requested: requested, config: ctx.config)
            if ctx.config.allDevices[name]?.isMac != true {
                _ = try await builds.provisioner.boot(name, in: &ctx)
            }
            device = name
        }
        if spec.needsBuild { try await ensureBuild(for: name, device: requested, in: &ctx) }
        if device == nil { device = try? builds.provisioner.deviceName(requested, config: ctx.config) }

        let context = ContextInfo.build(ctx: ctx, device: device, output: output)
        let invocation = Invocation("/bin/sh", ["-c", spec.run + " \"$@\"", "xcd-" + name] + arguments,
                                    environment: context.environment, workingDirectory: ctx.location.worktreeRoot,
                                    timeout: spec.timeoutDuration, passthrough: true)
        fflush(stdout)    // anything xcd printed before the child must not land after the child's output
        let result: ProcessOutput
        do {
            result = try await builds.runner.run(invocation)
        } catch var error as XcdError where error.code == .timeout {
            // Arguments pass through to the script, so `--timeout` would be the script's, not xcd's.
            error.message = "`xcd \(name)` timed out after \(DurationText.format(spec.timeoutDuration))"
            error.next = "make it finish sooner, or raise commands.\(name).timeout in .xcdev.yml, then re-run"
            throw error
        }
        switch result.exitCode {
        case 127: builds.progress("`xcd \(name)` exited 127: its command was not found; check commands.\(name).run in .xcdev.yml")
        case 126: builds.progress("`xcd \(name)` exited 126: its script is not executable; run `chmod +x` on it")
        default: break
        }
        return result.exitCode
    }

    /// $XCD_DEVICE, else defaultDevice, else the only device; errors name the command, not `--device`.
    func deviceForCommand(_ command: String, requested: String?, config: XcdevConfig) throws -> String {
        let names = config.allDevices.keys.sorted()
        if names.isEmpty {
            throw XcdError(.usage, "`xcd \(command)` needs a device, but .xcdev.yml has no devices",
                           next: "add one under `devices:` in .xcdev.yml (see `xcd config explain devices`)")
        }
        if requested == nil, config.defaultDevice == nil, names.count > 1 {
            throw XcdError(.usage, "`xcd \(command)` needs a device, and .xcdev.yml has several but no defaultDevice",
                           next: "set defaultDevice in .xcdev.yml, or run `XCD_DEVICE=<\(names.joined(separator: "|"))> xcd \(command)`")
        }
        return try builds.provisioner.deviceName(requested, config: config)
    }

    /// Builds the app for `device` unless this worktree already has a successful build for it.
    func ensureBuild(for command: String, device: String?, in ctx: inout WorktreeContext) async throws {
        let container = try ProjectContainer.resolve(config: ctx.config, worktreeRoot: ctx.location.worktreeRoot)
        let target = try builds.provisioner.targetName(device, container: container, config: ctx.config)
        guard try AppStateStore.load(ctx.paths).builds[target] == nil else { return }
        builds.progress("`xcd \(command)` needs a build of \(target); building first")
        let report = try await builds.build(BuildOptions(device: device), in: &ctx)
        guard report.succeeded else {
            throw XcdError(.buildFailed, "`xcd \(command)` needs a build, and the build failed with \(report.errors.count) error\(report.errors.count == 1 ? "" : "s")",
                           next: "fix the errors, then re-run `xcd \(command)`",
                           details: report.errors.map(\.text) + ["log: \(report.log)"])
        }
    }
}
