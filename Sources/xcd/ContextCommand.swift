import ArgumentParser
import XcdevKit

struct ContextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "context",
        abstract: "Print this worktree's context variables (XCD_*, DEVELOPER_DIR) for scripts and plugins.")
    @Option(help: "Include this device's clone (default: defaultDevice). Never clones.", completion: .devices)
    var device: String?
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try await Emit.run("context", options) { services in
            let ctx = try await services.open(worktree: options.worktree, runsPendingHook: false)
            return try ContextInfo.resolve(ctx: ctx, requestedDevice: device, provisioner: services.provisioner,
                                           output: services.output)
        }
    }
}
