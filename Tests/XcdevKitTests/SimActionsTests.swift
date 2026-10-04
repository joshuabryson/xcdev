import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct SimActionsTests {
    let fake = FakeProcessRunner()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-simact-\(UUID().uuidString)").path

    func context(_ yaml: String = """
    version: 1
    project: App.xcodeproj
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro" }
      old: { type: "iPhone 16", runtime: "iOS 26.5" }
    """) throws -> WorktreeContext {
        let state = WorktreeState(id: "id", name: "feat", project: "App", projectRoot: dir, path: dir, branch: "feat",
                                  xcode: XcodeInstall(path: "/Applications/Xcode.app", version: "27.0", build: "27A266a"),
                                  devices: [:], status: .ready, createdAt: Date())
        return WorktreeContext(location: ProjectLocation(projectRoot: dir, worktreeRoot: dir),
                               config: try ConfigLoader.parse(main: yaml), state: state)
    }

    var provisioner: DeviceProvisioner { DeviceProvisioner(runner: fake, globalPaths: GlobalPaths(base: dir + "/home")) }

    @Test func shutdownAndEraseOnNeverClonedDeviceAreNoOps() async throws {
        let ctx = try context()
        let shutdown = try await provisioner.shutdownReport(nil, in: ctx)
        #expect(shutdown.action == "not cloned" && shutdown.udid == nil && shutdown.device == "iphone")
        let erase = try await provisioner.eraseReport("old", in: ctx)
        #expect(erase.action == "not cloned" && erase.udid == nil && erase.device == "old")
        #expect(fake.calls.isEmpty)
    }

    @Test func eraseShutsDownThenErasesOnlyThatClone() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        var ctx = try context()
        let phone = try await provisioner.boot("iphone", in: &ctx)
        _ = try await provisioner.boot("old", in: &ctx)
        let before = fake.calls.count
        let report = try await provisioner.eraseReport("iphone", in: ctx)
        #expect(report.action == "erased" && report.udid == phone.device.udid)
        let lines = fake.commandLines.dropFirst(before).filter { $0.contains("simctl") }
        #expect(lines.count == 2)
        #expect(lines.first?.hasSuffix("simctl shutdown \(phone.device.udid)") == true)
        #expect(lines.last?.hasSuffix("simctl erase \(phone.device.udid)") == true)
        #expect(sims.device(named: "xcd · App · feat · iphone")?.state == "Shutdown")
    }

    @Test func shutdownReportsShutDown() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        var ctx = try context()
        let phone = try await provisioner.boot("iphone", in: &ctx)
        let report = try await provisioner.shutdownReport(nil, in: ctx)
        #expect(report.action == "shut down" && report.udid == phone.device.udid)
    }

    @Test func openBootsThenOpensSimulatorApp() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        var ctx = try context()
        let report = try await provisioner.openReport(nil, in: &ctx)
        let udid = try #require(report.udid)
        #expect(report.action == "opened")
        #expect(sims.devices.first { $0.udid == udid }?.state == "Booted")
        #expect(fake.commandLines.last?.contains("open -a Simulator --args -CurrentDeviceUDID \(udid)") == true)
    }

    @Test func bootReportsBooted() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        var ctx = try context()
        let report = try await provisioner.bootReport(nil, in: &ctx)
        #expect(report.action == "booted" && report.device == "iphone" && report.worktree == "feat")
    }

    @Test func contextDeviceFallback() throws {
        let ctx = try context()
        let error = #expect(throws: XcdError.self) {
            try ContextInfo.resolve(ctx: ctx, requestedDevice: "ipad", provisioner: provisioner)
        }
        #expect(error?.code == .deviceUnknown)
        #expect(try ContextInfo.resolve(ctx: ctx, requestedDevice: nil, provisioner: provisioner).device == "iphone")
        #expect(try ContextInfo.resolve(ctx: ctx, requestedDevice: "old", provisioner: provisioner).device == "old")

        let noDefault = try context("""
        version: 1
        project: App.xcodeproj
        devices:
          iphone: { type: "iPhone 18 Pro" }
          old: { type: "iPhone 16" }
        """)
        #expect(try ContextInfo.resolve(ctx: noDefault, requestedDevice: nil, provisioner: provisioner).device == nil)
    }

    @Test func shutdownStopsThatDevicesRecordingFirst() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        var ctx = try context()
        let phone = try await provisioner.boot("iphone", in: &ctx)
        let id = ProcessIdentity(pid: 4242, startTime: 1, arguments: ["simctl", "io", "recordVideo"])
        let detached = FakeDetachedProcesses(onStop: { _ in
            #expect(sims.devices.first { $0.udid == phone.device.udid }?.state == "Booted")   // still up while it stops
        })
        detached.adopt(id)
        try Recordings.save(RecordingRecord(device: "iphone", udid: phone.device.udid, path: dir + "/r.mp4", log: dir + "/r.log",
                                            process: id, startedAt: Date()), to: ctx.paths.recordingFile(device: "iphone"))
        let report = try await provisioner.shutdownReport(nil, in: ctx, detached: detached)
        #expect(detached.stops == [.init(pid: 4242, signal: SIGINT)])
        #expect(report.notes.count == 1 && report.text.contains("\nstopped the iphone recording after"))
    }
}
