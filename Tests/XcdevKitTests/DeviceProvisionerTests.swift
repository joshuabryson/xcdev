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

    @Test func sameNamedProjectsKeepEachOthersClones() async throws {
        let dirB = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-prov-\(UUID().uuidString)").path
        defer {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.removeItem(atPath: dirB)
        }
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        func mainContext(_ root: String) throws -> WorktreeContext {
            var ctx = try context()
            ctx.state.name = "main"
            ctx.state.projectRoot = root
            ctx.state.path = root
            return WorktreeContext(location: ProjectLocation(projectRoot: root, worktreeRoot: root),
                                   config: ctx.config, state: ctx.state)
        }
        var a = try mainContext(dir)
        var b = try mainContext(dirB)
        let deviceA = try await provisioner.ensure("iphone", in: &a)
        let deviceB = try await provisioner.ensure("iphone", in: &b)
        #expect(deviceA.udid != deviceB.udid)
        #expect(sims.devices.contains { $0.udid == deviceA.udid })
        #expect(sims.devices.filter { $0.name == "xcd · App · main · iphone" }.count == 2)
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
        #expect(error?.code == .platformUnsupported)
        #expect(error?.next?.contains("xcd launch --device mac --show") == true)
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
            "XCD_MEDIA_DIR": dir + "/.xcdev-media/feat/nobranch",
            "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
        ])
        #expect(info.text.hasPrefix("DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer\nXCD_DERIVED_DATA="))
        let unprovisioned = ContextInfo.build(ctx: ctx, device: "old")
        #expect(unprovisioned.environment["XCD_UDID"] == nil)
        #expect(unprovisioned.environment["XCD_DEVICE"] == "old")
    }

    @Test func mediaDirFollowsTheDeviceAndIsAContractKey() throws {
        let ctx = try context()
        #expect(ContextInfo.build(ctx: ctx, device: nil).mediaDir == dir + "/.xcdev-media/feat/nobranch")
        let custom = try context("""
        version: 1
        project: App.xcodeproj
        defaultDevice: iphone
        devices:
          iphone: { type: "iPhone 18 Pro" }
        ui: { media: { dir: "shots/{device}" } }
        """)
        #expect(ContextInfo.build(ctx: custom, device: nil).mediaDir == dir + "/shots/iphone")
        #expect(ContextInfo.beforeBuild(ctx: custom, device: "iphone").environment["XCD_MEDIA_DIR"] == dir + "/shots/iphone")
        #expect(ContextInfo.worktree(custom.state, config: custom.config).mediaDir == dir + "/shots/iphone")
        #expect(ContextInfo.worktree(custom.state, config: nil).mediaDir == dir + "/.xcdev-media/feat/nobranch")
        #expect(ContextInfo.contractKeys.contains("XCD_MEDIA_DIR"))
        #expect(ContextInfo.childEnvironment(inherited: ["XCD_MEDIA_DIR": "/parent"], overrides: [:])["XCD_MEDIA_DIR"] == nil)
    }

    @Test func xcodeOverrideIsUsedButNeverPinned() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        var ctx = try context()
        ctx.state.xcode = nil
        let beta = XcodeInstall(path: "/Applications/Xcode-beta.app", version: "27.1", build: "27B5")
        ctx.xcodeOverride = beta
        #expect(try await provisioner.ensureXcode(&ctx) == beta)
        _ = try await provisioner.ensure("iphone", in: &ctx)
        #expect(ctx.state.xcode == nil)
        #expect(try WorktreeStateStore.load(ctx.paths)?.xcode == nil)
        #expect(fake.calls.filter { $0.argv[0] == "xcrun" }.allSatisfy {
            $0.environment["DEVELOPER_DIR"] == "/Applications/Xcode-beta.app/Contents/Developer"
        })
    }

    @Test func pinnedCloneTooNewForOverrideIsAMismatch() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        var ctx = try context()
        _ = try await provisioner.ensure("iphone", in: &ctx)          // clones on iOS 27.0 with Xcode 27.0
        let old = XcodeInstall(path: "/Applications/Xcode-26.5.app", version: "26.5", build: "26F1")
        fake.stub(["xcrun", "xcodebuild", "-showsdks", "-json"]) { inv in
            ProcessOutput(stdout: inv.environment["DEVELOPER_DIR"] == old.developerDir
                ? #"[{"platform":"iphonesimulator","sdkVersion":"26.5"}]"#
                : FakeSimulators.sdksJSON)
        }
        ctx.xcodeOverride = old
        let error = await #expect(throws: XcdError.self) { try await provisioner.ensure("iphone", in: &ctx) }
        #expect(error?.code == .xcodeRuntimeMismatch)
        #expect(error?.message.hasPrefix("iOS 27.0 (devices.iphone) is newer than Xcode 26.5") == true)
    }
}
