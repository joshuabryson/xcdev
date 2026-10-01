import ArgumentParser
import XcdevKit

struct ContextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "context",
        abstract: "Print this worktree's context variables (XCD_*, DEVELOPER_DIR) for scripts and plugins.")
    @Option(help: "Include this device's clone (default: defaultDevice). Never clones.") var device: String?
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("context", options) { services in
            let ctx = try await services.open(worktree: options.worktree)
            // An explicit --device must be valid; without one, fall back to the default if there is one.
            let name = device != nil
                ? try services.provisioner.deviceName(device, config: ctx.config)
                : try? services.provisioner.deviceName(nil, config: ctx.config)
            return ContextInfo.build(ctx: ctx, device: name)
        }
    }
}
