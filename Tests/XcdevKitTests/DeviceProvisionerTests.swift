import Foundation
import Synchronization
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct DeviceProvisionerTests {
    let fake = FakeProcessRunner()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-prov-\(UUID().uuidString)").path

    func context(_ yaml: String = """
    version: 1
    project: App.xcodeproj
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro" }
      old: { type: "iPhone 16", runtime: "iOS 26.5" }
      watch: { type: "Apple Watch Series 11 (46mm)", pairWith: iphone }
      mac: { platform: macOS }
    """) throws -> WorktreeContext {
        let state = WorktreeState(id: "id", name: "feat", project: "App", projectRoot: dir, path: dir, branch: "feat",
                                  xcode: XcodeInstall(path: "/Applications/Xcode.app", version: "27.0", build: "27A266a"),
                                  devices: [:], status: .ready, createdAt: Date())
        return WorktreeContext(location: ProjectLocation(projectRoot: dir, worktreeRoot: dir),
                               config: try ConfigLoader.parse(main: yaml), state: state)
    }

    var provisioner: DeviceProvisioner { DeviceProvisioner(runner: fake, globalPaths: GlobalPaths(base: dir + "/home")) }

    @Test func deviceNameDefaultsAndValidates() throws {
        let config = try context().config
        #expect(try provisioner.deviceName(nil, config: config) == "iphone")
        #expect(try provisioner.deviceName("old", config: config) == "old")
        let error = #expect(throws: XcdError.self) { try provisioner.deviceName("ipad", config: config) }
        #expect(error?.code == .deviceUnknown)
        #expect(error?.next == "use one of: iphone, mac, old, watch")
    }

    @Test func ensureClonesOnceAndPinsRuntime() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        var ctx = try context()
        let device = try await provisioner.ensure("iphone", in: &ctx)
        #expect(device.runtime == "iOS 27.0")
        #expect(sims.device(named: "xcd · App · feat · iphone")?.udid == device.udid)
        #expect(sims.createCount == 1 && sims.cloneCount == 1)
        #expect(try WorktreeStateStore.load(ctx.paths)?.devices["iphone"] == device)
        #expect(fake.calls.allSatisfy { $0.argv[0] != "xcrun" || $0.environment["DEVELOPER_DIR"] == "/Applications/Xcode.app/Contents/Developer" })

        let again = try await provisioner.ensure("iphone", in: &ctx)
        #expect(again == device)
        #expect(sims.cloneCount == 1)
    }

    @Test func recreatesCloneDeletedExternally() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        var ctx = try context()
        let first = try await provisioner.ensure("old", in: &ctx)
        sims.deleteExternally(udid: first.udid)
        let second = try await provisioner.ensure("old", in: &ctx)
        #expect(second.udid != first.udid)
        #expect(second.runtime == "iOS 26.5")            // pinned runtime survives
        #expect(sims.createCount == 1)                    // template reused
    }

    @Test func watchIsPairedWithPhone() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        var ctx = try context()
        let watch = try await provisioner.ensure("watch", in: &ctx)
        let phone = try #require(ctx.state.devices["iphone"])
        #expect(sims.pairs == [[watch.udid, phone.udid]])
    }

    @Test func failedPairingIsRetried() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        let attempts = Counter()
        let paired = Mutex<[[String]]>([])
        fake.stub(["xcrun", "simctl", "pair"]) { inv in
            if attempts.increment() == 1 { return ProcessOutput(exitCode: 1, stderr: "pair failed") }
            paired.withLock { $0.append([inv.arguments[2], inv.arguments[3]]) }
            return ProcessOutput()
        }
        var ctx = try context()
        await #expect(throws: (any Error).self) { try await provisioner.ensure("watch", in: &ctx) }
        #expect(ctx.state.devices["watch"]?.pairedWith == nil)
        let clonesAfterFailure = sims.cloneCount
        let watch = try await provisioner.ensure("watch", in: &ctx)
        let phone = try #require(ctx.state.devices["iphone"])
        #expect(paired.withLock { $0 } == [[watch.udid, phone.udid]])
        #expect(watch.pairedWith == phone.udid)
        #expect(sims.cloneCount == clonesAfterFailure)
    }

    @Test func watchIsRepairedWhenPhoneIsRecloned() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        var ctx = try context()
        _ = try await provisioner.ensure("watch", in: &ctx)
        let oldPhone = try #require(ctx.state.devices["iphone"])
        sims.deleteExternally(udid: oldPhone.udid)
        let watch = try await provisioner.ensure("watch", in: &ctx)
        let newPhone = try #require(ctx.state.devices["iphone"])
        #expect(newPhone.udid != oldPhone.udid)
        #expect(watch.pairedWith == newPhone.udid)
        #expect(sims.pairs.count == 2)
    }

    @Test func macDeviceIsRejected() async throws {
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        var ctx = try context()
        let error = await #expect(throws: XcdError.self) { try await provisioner.ensure("mac", in: &ctx) }
        #expect(error?.code == .usage)
    }

    @Test func bootClonesThenBoots() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        var ctx = try context()
        let (device, retries) = try await provisioner.boot("iphone", in: &ctx)
        #expect(retries == 0)
        #expect(sims.devices.first { $0.udid == device.udid }?.state == "Booted")
    }

    @Test func xcodeIsPinnedOnFirstUse() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        fake.stub(["mdfind"], stdout: "")
        fake.stub(["xcode-select", "-p"], stdout: "/Applications/Xcode.app/Contents/Developer\n")
        var ctx = try context()
        ctx.state.xcode = nil
        let apps = dir + "/Apps"
        try XcodeTests.makeFakeXcode(at: apps + "/Xcode.app", version: "27.0", build: "27A266a")
        let p = DeviceProvisioner(runner: fake, globalPaths: GlobalPaths(base: dir + "/home"),
                                  discovery: XcodeDiscovery(runner: fake, applicationsDirectories: [apps]))
        let xcode = try await p.ensureXcode(&ctx)
        #expect(xcode.build == "27A266a")
        #expect(try WorktreeStateStore.load(ctx.paths)?.xcode == xcode)
    }

    @Test func contextEnvironment() throws {
        var ctx = try context()
        ctx.state.devices["iphone"] = ProvisionedDevice(udid: "U", deviceType: "iPhone 18 Pro", deviceTypeIdentifier: "t",
                                                        runtime: "iOS 27.0", runtimeIdentifier: "r")
        let info = ContextInfo.build(ctx: ctx, device: "iphone")
        #expect(info.environment == [
            "XCD_PROJECT_ROOT": dir, "XCD_WORKTREE": dir, "XCD_WORKTREE_NAME": "feat",
            "XCD_DEVICE": "iphone", "XCD_UDID": "U", "XCD_RUNTIME": "iOS 27.0",
            "XCD_DERIVED_DATA": dir + "/.xcdev/DerivedData",
            "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
        ])
        #expect(info.text.hasPrefix("DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer\nXCD_DERIVED_DATA="))
        let unprovisioned = ContextInfo.build(ctx: ctx, device: "old")
        #expect(unprovisioned.environment["XCD_UDID"] == nil)
        #expect(unprovisioned.environment["XCD_DEVICE"] == "old")
    }
}
