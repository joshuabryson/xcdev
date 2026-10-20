import Foundation
import Synchronization
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd sim fold` and the foldable's `ui rotate`.
@Suite struct PostureServiceTests {
    let worktree = FakeWorktree(prefix: "xcd posture")
    let yaml = """
    version: 1
    project: App.xcodeproj
    defaultDevice: duo
    devices:
      duo: { type: "iPhone Duo" }
      iphone: { type: "iPhone 18 Pro" }
    """

    /// A catalog with the Duo and a phone on one runtime the fake Xcode's SDK supports (iOS 27.0).
    static let catalogJSON = """
    {
      "devicetypes" : [
        { "name" : "iPhone 18 Pro", "identifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", "productFamily" : "iPhone" },
        { "name" : "iPhone Duo", "identifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo", "productFamily" : "iPhone" }
      ],
      "runtimes" : [
        { "name" : "iOS 27.0", "identifier" : "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version" : "27.0", "platform" : "iOS",
          "isAvailable" : true, "buildversion" : "25A5295e",
          "supportedDeviceTypes" : [
            { "identifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", "name" : "iPhone 18 Pro", "productFamily" : "iPhone" },
            { "identifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo", "name" : "iPhone Duo", "productFamily" : "iPhone" } ] }
      ],
      "devices" : { "com.apple.CoreSimulator.SimRuntime.iOS-27-0" : [] }
    }
    """

    /// An override whose constraints the fake Xcode (27.0) and runtime (27.0) meet, so a recipe is found.
    static let overrideJSON = """
    { "version": 1, "foldableDeviceTypes": [], "direct": [ {
        "xcode": ">=27.0", "runtime": ">=27.0",
        "feature": "com.apple.coredevice.feature.remote.hid.vendordefined", "messageType": "IndigoVendorDefinedEvent",
        "usagePage": 65377, "usage": 91, "version": 0, "provider": "com.apple.Virtualization.VirtualMachines",
        "hinge": { "source": "hinge-slider-control", "type": "range" },
        "orientation": { "source": "orientation-picker-control", "type": "enum",
                         "values": { "portrait": "portrait", "landscape-left": "landscape-left", "landscape-right": "landscape-right" } } } ] }
    """

    /// A clock that moves one second per reading, so a witness loop ends.
    final class Clock: Sendable {
        let now: Mutex<Date>
        init(_ start: Date) { now = Mutex(start) }
        func read() -> Date { now.withLock { $0.addTimeInterval(1); return $0 } }
    }

    func setup(routes: [any PostureRoute] = [], start: String = "2026-10-17 19:00:00.000") throws -> (PostureService, WorktreeContext) {
        _ = try FakeSimulators(runner: worktree.runner, catalogJSON: Self.catalogJSON)
        let home = worktree.root + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try Self.overrideJSON.write(toFile: home + "/posture-recipes.json", atomically: true, encoding: .utf8)
        let clock = Clock(try #require(PoseLine.timestamp(start)))
        let service = PostureService(provisioner: worktree.provisioner, globalPaths: GlobalPaths(base: home), routes: routes,
                                     now: { clock.read() }, sleep: { _ in await Task.yield() })
        return (service, try worktree.context(yaml))
    }

    func stubDisplays(_ fixture: String, orientation: String = "portrait") throws {
        let json = Fixture.string(fixture).replacingOccurrences(of: "\"portrait\"", with: "\"\(orientation)\"")
        worktree.runner.stub(["xcrun", "devicectl", "device", "info", "displays"], stdout: json)
    }

    func line(_ time: String, _ degrees: String, _ state: String) -> String {
        "\(time) Df SpringBoard[88269:1063c187] [com.apple.SpringBoard:DevicePose] DCMPose: \(degrees)° (0.00 fold:0.00): \(state) [device:Pu]\n"
    }

    @Test func withNoArgumentFoldBootsTheCloneAndReportsThePosture() async throws {
        defer { worktree.remove() }
        var (service, ctx) = try setup()
        try stubDisplays("devicectl-displays-closed.json")
        worktree.runner.stub(["xcrun", "simctl", "spawn"], stdout: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"))
        let report = try await service.fold(FoldOptions(), in: &ctx)
        #expect(report.text == "posture: closed (0°)  display: cover  orientation: portrait")
        #expect(report.device == "duo" && report.route == nil && report.verified && !report.already)
        #expect(report.udid == ctx.state.devices["duo"]?.udid)
        #expect(worktree.runner.commandLines.contains { $0.contains("simctl bootstatus") })
    }

    @Test func aDeviceWithoutAHingeIsRefusedNamingTheFoldables() async throws {
        defer { worktree.remove() }
        var (service, ctx) = try setup()
        try stubDisplays("devicectl-displays-closed.json")
        worktree.runner.stub(["xcrun", "simctl", "spawn"], stdout: "")
        _ = try await service.fold(FoldOptions(), in: &ctx)        // provisions the duo, so the hint can name it
        let error = await #expect(throws: XcdError.self) { try await service.fold(FoldOptions(device: "iphone"), in: &ctx) }
        #expect(error?.code == .platformUnsupported)
        #expect(error?.message == "device 'iphone' (iPhone 18 Pro) has no hinge")
        #expect(error?.next == "pass --device duo")
    }

    @Test func isFoldableAnswersByTheClonesDeviceType() async throws {
        defer { worktree.remove() }
        var (service, ctx) = try setup()
        #expect(try await service.isFoldable(device: "duo", in: &ctx))
        let phone = try await service.isFoldable(device: "iphone", in: &ctx)
        #expect(!phone)
        #expect(try await service.isFoldable(device: nil, in: &ctx))        // the default device is the duo
    }
}
