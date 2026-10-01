import ArgumentParser
import XcdevKit

struct SimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sim",
        abstract: "Control this worktree's simulator clones.",
        subcommands: [Boot.self, Shutdown.self, Erase.self, Open.self]
    )

    struct DeviceOption: ParsableArguments {
        @Option(help: "Device name from .xcdev.yml (default: defaultDevice).") var device: String?
    }

    struct Boot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Boot the device's clone, cloning it first if needed.")
        @OptionGroup var target: DeviceOption
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("sim boot", options) { services in
                var ctx = try await services.open(worktree: options.worktree)
                let name = try services.provisioner.deviceName(target.device, config: ctx.config)
                let (device, retries) = try await services.provisioner.boot(name, in: &ctx)
                return SimReport(action: "booted", device: name, udid: device.udid, retries: retries, worktree: ctx.state.name)
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
                let name = try services.provisioner.deviceName(target.device, config: ctx.config)
                guard let device = ctx.state.devices[name] else {
                    return SimReport(action: "not cloned", device: name, udid: nil, retries: 0, worktree: ctx.state.name)
                }
                let retries = try await services.provisioner.simctl(for: ctx).shutdown(udid: device.udid)
                return SimReport(action: "shut down", device: name, udid: device.udid, retries: retries, worktree: ctx.state.name)
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
                let name = try services.provisioner.deviceName(target.device, config: ctx.config)
                guard let device = ctx.state.devices[name] else {
                    return SimReport(action: "not cloned", device: name, udid: nil, retries: 0, worktree: ctx.state.name)
                }
                let simctl = services.provisioner.simctl(for: ctx)
                let retries = try await simctl.shutdown(udid: device.udid)
                try await simctl.erase(udid: device.udid)
                return SimReport(action: "erased", device: name, udid: device.udid, retries: retries, worktree: ctx.state.name)
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
                let name = try services.provisioner.deviceName(target.device, config: ctx.config)
                let (device, retries) = try await services.provisioner.boot(name, in: &ctx)
                try await services.provisioner.simctl(for: ctx).openSimulatorApp(udid: device.udid)
                return SimReport(action: "opened", device: name, udid: device.udid, retries: retries, worktree: ctx.state.name)
            }
        }
    }
}
