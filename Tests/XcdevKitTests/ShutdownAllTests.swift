import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct ShutdownAllTests {
    static let yaml = """
    version: 1
    project: App.xcodeproj
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro" }
      ipad: { type: "iPad Pro 13-inch (M5)" }
      watch: { type: "Apple Watch Series 11 (46mm)", pairWith: iphone }
      mac: { platform: macOS }
    """
    let worktree = FakeWorktree(prefix: "xcd shutall")
    let holds = LeaseHolds()
    let detached = FakeDetachedProcesses()
    let simulators: FakeSimulators
    let iphone: String
    let ipad: String
    let ctx: WorktreeContext
    var home: String { worktree.root + "/home" }
    var leases: DeviceLeases { DeviceLeases(globalPaths: GlobalPaths(base: home), holds: holds) }
    var provisioner: DeviceProvisioner { DeviceProvisioner(runner: worktree.runner, globalPaths: GlobalPaths(base: home)) }

    init() throws {
        simulators = try FakeSimulators(runner: worktree.runner, catalogJSON: Fixture.string("simctl-list.json"))
        iphone = simulators.add(name: "xcd · App · feat · iphone", state: "Booted")
        ipad = simulators.add(name: "xcd · App · feat · ipad", state: "Shutdown")
        var ctx = try worktree.context(Self.yaml)
        for (name, udid) in [("iphone", iphone), ("ipad", ipad)] {
            ctx.state.devices[name] = ProvisionedDevice(udid: udid, deviceType: "t", deviceTypeIdentifier: "t", runtime: "r",
                                                        runtimeIdentifier: "r")
        }
        self.ctx = ctx
    }

    func cleanUp() {
        holds.release(iphone)
        holds.release(ipad)
        worktree.remove()
    }

    func state(_ udid: String) -> String? { simulators.devices.first { $0.udid == udid }?.state }

    @Test func everyBootedCloneIsShutDownAndItsSessionEnded() async throws {
        defer { cleanUp() }
        try leases.save(.sample(udid: iphone))
        try leases.save(.sample(udid: ipad))
        let watchdogs = Watchdogs(leases: leases, detached: detached)
        try await watchdogs.start(iphone, developerDir: nil, log: "/l", executable: "/xcd")
        let watchdogPid = try #require(detached.starts.first).identity.pid
        let id = ProcessIdentity(pid: 5252, startTime: 1, arguments: ["xcodebuild", "test-without-building"])
        detached.adopt(id)
        try Runners.save(RunnerRecord(device: "iphone", udid: iphone, process: id, token: "t", port: 1, runnerKey: "k", log: "/l",
                                      readyFile: "/r", startedAt: Date(), restarts: [], failed: false),
                         to: ctx.paths.runnerFile(device: "iphone"))

        let report = try await provisioner.shutdownAllReport(in: ctx, detached: detached)
        #expect(report.devices.map(\.device) == ["ipad", "iphone", "watch"])
        #expect(report.devices.map(\.action) == ["not booted", "shut down", "not cloned"])
        #expect(state(iphone) == "Shutdown")
        #expect(worktree.runner.commandLines.filter { $0.contains("simctl shutdown") }.count == 1)
        #expect(leases.load(iphone) == nil && leases.load(ipad) == nil)
        #expect(detached.stops.contains { $0.pid == watchdogPid && $0.signal == SIGTERM })
        #expect(report.text == """
            ipad: not booted
            shut down iphone  udid=\(iphone)
            stopped the iphone UI runner
            watch: not cloned
            """)
    }

    @Test func nothingBootedIsOneLine() async throws {
        defer { cleanUp() }
        simulators.setState("Shutdown", udid: iphone)
        let report = try await provisioner.shutdownAllReport(in: ctx, detached: detached)
        #expect(report.text == "nothing booted in feat")
    }

    @Test func theJSONListsEveryDevice() throws {
        let report = ShutdownAllReport(devices: [.init(device: "ipad", udid: "U2", action: "not booted", retries: 0, notes: [])],
                                       worktree: "main")
        #expect(Renderer.report(report, command: "sim shutdown", format: .json, notes: []).contains(
            #""data":{"devices":[{"action":"not booted","device":"ipad","notes":[],"retries":0,"udid":"U2"}],"worktree":"main"}"#))
    }

    @Test func allAndDeviceTogetherIsUsage() throws {
        #expect(try ShutdownScope.parse(all: true, device: nil) == .all)
        #expect(try ShutdownScope.parse(all: false, device: "ipad") == .one("ipad"))
        let error = #expect(throws: XcdError.self) { try ShutdownScope.parse(all: true, device: "ipad") }
        #expect(error?.code == .usage)
        #expect(error?.message == "--all and --device can't be combined")
        #expect(error?.next == "pass one of them")
    }
}
