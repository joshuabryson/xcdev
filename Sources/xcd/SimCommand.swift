import ArgumentParser
import XcdevKit

struct SimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sim",
        abstract: "Control this worktree's simulator clones.",
        subcommands: [Boot.self, Shutdown.self, Erase.self, Open.self]
    )

    struct DeviceOption: ParsableArguments {
        @Option(help: "Device name from .xcdev.yml (default: defaultDevice).", completion: .devices) var device: String?
    }

    struct Boot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Boot the device's clone, cloning it first if needed.")
        @OptionGroup var target: DeviceOption
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("sim boot", options) { services in
                var ctx = try await services.open(worktree: options.worktree)
                return try await services.provisioner.bootReport(target.device, in: &ctx)
            }
        }
    }

    struct Shutdown: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shut down the device's clone (no-op if never cloned).")
        @OptionGroup var target: DeviceOption
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("sim shutdown", options) { services in
                let ctx = try await services.open(worktree: options.worktree)
                return try await services.provisioner.shutdownReport(target.device, in: ctx)
            }
        }
    }

    struct Erase: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Shut down and erase the device's clone (no-op if never cloned).")
        @OptionGroup var target: DeviceOption
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("sim erase", options) { services in
                let ctx = try await services.open(worktree: options.worktree)
                return try await services.provisioner.eraseReport(target.device, in: ctx)
            }
        }
    }

    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Boot the clone and show it in Simulator.app so a human can watch.")
        @OptionGroup var target: DeviceOption
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("sim open", options) { services in
                var ctx = try await services.open(worktree: options.worktree)
                return try await services.provisioner.openReport(target.device, in: &ctx)
            }
        }
    }
}
