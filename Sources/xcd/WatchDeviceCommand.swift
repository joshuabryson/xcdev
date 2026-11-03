import ArgumentParser
import XcdevKit

/// The detached watchdog a command starts for each clone it boots (`Watchdogs.start`). Hidden from help. Its stderr
/// is its log. It is dispatched before `Interrupts` is installed, so the SIGTERM that `sim shutdown`, `sim erase`,
/// and `wt remove` send ends it plainly.
struct WatchDeviceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: Watchdogs.marker,
                                                    abstract: "Shut one simulator clone down once its lease goes stale.",
                                                    shouldDisplay: false)
    @Argument(help: "The clone's udid.") var udid: String
    @Option(name: .customLong("developer-dir"), help: "The Xcode that runs simctl; without it, xcode-select's.")
    var developerDir: String?

    func run() async throws {
        var watchdog = DeviceWatchdog(udid: udid, leases: DeviceLeases(globalPaths: .live()),
                                      simctl: SimctlClient(runner: SystemProcessRunner(), developerDir: developerDir),
                                      detached: SystemDetachedProcesses(), log: { StandardError.write($0 + "\n") })
        let code = await watchdog.run { try? await Task.sleep(for: $0) }
        if code != 0 { throw ExitCode(code) }
    }
}
