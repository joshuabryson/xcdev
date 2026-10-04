import ArgumentParser
import XcdevKit

struct SimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sim",
        abstract: "Control this worktree's simulator clones.",
        subcommands: [Boot.self, Shutdown.self, Erase.self, Open.self, OpenURL.self, Push.self, Privacy.self, StatusBar.self,
                      Appearance.self, Location.self, Pasteboard.self, AddMedia.self, UICommand.Screenshot.self, UICommand.Record.self]
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
                await Recording.stopOverdue(services, ctx)
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
                return try await services.provisioner.shutdownReport(target.device, in: ctx, detached: services.detached)
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
                return try await services.provisioner.eraseReport(target.device, in: ctx, detached: services.detached)
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
                await Recording.stopOverdue(services, ctx)
                return try await services.provisioner.openReport(target.device, in: &ctx)
            }
        }
    }

    struct OpenURL: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "open-url", abstract: "Open a URL (deep link or universal link) on the device.")
        @Argument(help: "The URL, e.g. myapp://settings or https://example.com/item/1.") var url: String
        @OptionGroup var target: DeviceOption
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("sim open-url", options) { services in
                var ctx = try await services.open(worktree: options.worktree)
                await Recording.stopOverdue(services, ctx)
                return try await services.deviceState.openURL(url, device: target.device, in: &ctx)
            }
        }
    }

    struct Push: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Send a push notification to the app.",
                                                        discussion: "The app must be installed and have asked for notification permission.")
        @Option(help: "Alert text; xcd builds the payload.") var alert: String?
        @Option(help: "A JSON payload file with an \"aps\" key.", completion: .file(extensions: ["json"])) var file: String?
        @Option(help: "Bundle id (default: the app of the last build for this device).") var bundle: String?
        @OptionGroup var target: DeviceOption
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("sim push", options) { services in
                var ctx = try await services.open(worktree: options.worktree)
                await Recording.stopOverdue(services, ctx)
                return try await services.deviceState.push(alert: alert, file: file, bundle: bundle, device: target.device, in: &ctx)
            }
        }
    }

    struct Privacy: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Grant, revoke, or reset a privacy permission without a prompt.")
        @Argument(help: "grant, revoke, or reset.", completion: .list(PrivacyAction.allCases.map(\.rawValue))) var action: String
        @Argument(help: "The service, e.g. photos, location, microphone, camera, or all.",
                  completion: .list(SimctlClient.privacyServices + ["camera"])) var service: String
        @Option(help: "Bundle id (default: the app of the last build for this device).") var bundle: String?
        @OptionGroup var target: DeviceOption
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("sim privacy", options) { services in
                guard let parsed = PrivacyAction(rawValue: action) else {
                    throw XcdError(.usage, "'\(action)' is not grant, revoke, or reset", next: "e.g. `xcd sim privacy grant photos`")
                }
                var ctx = try await services.open(worktree: options.worktree)
                await Recording.stopOverdue(services, ctx)
                return try await services.deviceState.privacy(parsed, service: service, bundle: bundle, device: target.device, in: &ctx)
            }
        }
    }

    struct StatusBar: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status-bar", abstract: "Override the status bar (time, battery, signal), or --clear it.")
        @Option(help: "Time text, e.g. 9:41 (an ISO 8601 date also sets the date).") var time: String?
        @Option(help: "Battery level, 0-100.") var battery: Int?
        @Option(name: .customLong("battery-state"), help: "charged, charging, or discharging.",
                completion: .list(StatusBarOverrides.batteryStates)) var batteryState: String?
        @Option(help: "Wi-Fi bars, 0-3.") var wifi: Int?
        @Option(help: "Cellular bars, 0-4.") var cellular: Int?
        @Option(help: "Data network: hide, wifi, 3g, 4g, lte, lte-a, lte+, 5g, 5g+, 5g-uwb, or 5g-uc.",
                completion: .list(StatusBarOverrides.networks)) var network: String?
        @Option(name: .customLong("operator"), help: "Carrier name ('' for none).") var operatorName: String?
        @Flag(help: "Remove every override.") var clear = false
        @OptionGroup var target: DeviceOption
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("sim status-bar", options) { services in
                let overrides = StatusBarOverrides(time: time, batteryLevel: battery, batteryState: batteryState, wifiBars: wifi,
                                                   cellularBars: cellular, network: network, operatorName: operatorName)
                if clear, !overrides.isEmpty {
                    throw XcdError(.usage, "--clear can't be combined with values", next: "pass either --clear or the values to set")
                }
                var ctx = try await services.open(worktree: options.worktree)
                await Recording.stopOverdue(services, ctx)
                return try await services.deviceState.statusBar(clear ? nil : overrides, device: target.device, in: &ctx)
            }
        }
    }

    struct Appearance: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Switch the device to light or dark mode.")
        @Argument(help: "light or dark.", completion: .list(XcdevKit.Appearance.allCases.map(\.rawValue))) var mode: String
        @OptionGroup var target: DeviceOption
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("sim appearance", options) { services in
                guard let value = XcdevKit.Appearance(rawValue: mode) else {
                    throw XcdError(.usage, "'\(mode)' is not light or dark", next: "e.g. `xcd sim appearance dark`")
                }
                var ctx = try await services.open(worktree: options.worktree)
                await Recording.stopOverdue(services, ctx)
                return try await services.deviceState.appearance(value, device: target.device, in: &ctx)
            }
        }
    }

    struct Location: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Simulate a location (latitude,longitude), or --clear it.")
        @Argument(help: "e.g. 37.33,-122.03") var coordinate: String?
        @Flag(help: "Stop simulating a location.") var clear = false
        @OptionGroup var target: DeviceOption
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("sim location", options) { services in
                guard clear != (coordinate != nil) else {
                    throw XcdError(.usage, "pass a coordinate or --clear", next: "e.g. `xcd sim location 37.33,-122.03`")
                }
                let parsed = try coordinate.map(Coordinate.parse)
                var ctx = try await services.open(worktree: options.worktree)
                await Recording.stopOverdue(services, ctx)
                return try await services.deviceState.location(parsed, device: target.device, in: &ctx)
            }
        }
    }

    struct Pasteboard: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set or read the device's pasteboard (text).", subcommands: [SetText.self, GetText.self])

        struct SetText: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "set", abstract: "Put text on the device's pasteboard.")
            @Option(help: "The text.") var text: String
            @OptionGroup var target: DeviceOption
            @OptionGroup var options: GlobalOptions

            func run() async throws {
                try await Emit.run("sim pasteboard set", options) { services in
                    var ctx = try await services.open(worktree: options.worktree)
                    await Recording.stopOverdue(services, ctx)
                    return try await services.deviceState.setPasteboard(text: text, device: target.device, in: &ctx)
                }
            }
        }

        struct GetText: AsyncParsableCommand {
            static let configuration = CommandConfiguration(commandName: "get", abstract: "Print the device's pasteboard text, and nothing else.")
            @OptionGroup var target: DeviceOption
            @OptionGroup var options: GlobalOptions

            func run() async throws {
                try await Emit.run("sim pasteboard get", options) { services in
                    var ctx = try await services.open(worktree: options.worktree)
                    await Recording.stopOverdue(services, ctx)
                    return try await services.deviceState.pasteboard(device: target.device, in: &ctx)
                }
            }
        }
    }

    struct AddMedia: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "addmedia", abstract: "Add photos or videos to the device's Photos library.")
        @Argument(help: "Image or video files.", completion: .file()) var files: [String]
        @OptionGroup var target: DeviceOption
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("sim addmedia", options) { services in
                var ctx = try await services.open(worktree: options.worktree)
                await Recording.stopOverdue(services, ctx)
                let absolute = files.map { $0.hasPrefix("/") ? $0 : services.currentDirectory + "/" + $0 }
                return try await services.deviceState.addMedia(absolute, device: target.device, in: &ctx)
            }
        }
    }
}
