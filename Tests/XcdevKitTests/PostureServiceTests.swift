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

    /// A route that records what it was asked and flips a flag the process stubs read, so the "after" state appears.
    final class FakeRoute: PostureRoute, Sendable {
        let id = PostureRouteID.direct
        let applied = Mutex<[PostureRequest]>([])
        let sent = Mutex(false)
        let state = Mutex(RouteAvailability.available)

        func availability(_ ctx: PostureContext) -> RouteAvailability { state.withLock { $0 } }

        func apply<Result: Sendable>(_ request: PostureRequest, _ ctx: PostureContext,
                                     holdingUntil witness: () async throws -> Result) async throws -> Result {
            applied.withLock { $0.append(request) }
            sent.withLock { $0 = true }
            return try await witness()
        }
    }

    /// Before the send the clone is closed with the given line; after it, devicectl says `after` and the log `afterLines`.
    func stubBeforeAndAfter(_ route: FakeRoute, before: String, after: String, afterLines: String) throws {
        let closed = Fixture.string("devicectl-displays-closed.json")
        let later = Fixture.string(after)
        worktree.runner.stub(["xcrun", "devicectl", "device", "info", "displays"]) { _ in
            ProcessOutput(stdout: route.sent.withLock { $0 } ? later : closed)
        }
        worktree.runner.stub(["xcrun", "simctl", "spawn"]) { invocation in
            ProcessOutput(stdout: invocation.arguments.contains("boot") ? before : afterLines)
        }
    }

    @Test func openIsSentAndVerifiedByTheHingeLine() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"),
                               after: "devicectl-displays-open.json", afterLines: line("2026-10-17 20:00:01.000", "180.0", "openFlat"))
        let report = try await service.fold(FoldOptions(posture: .open), in: &ctx)
        #expect(route.applied.withLock { $0 } == [.hinge(degrees: 180)])
        #expect(report.text == "posture: open (180°)  display: inner  orientation: portrait  route: direct")
        #expect(report.verified && !report.already && report.route == "direct")
    }

    @Test func alreadyThereSendsNothing() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"),
                               after: "devicectl-displays-closed.json", afterLines: "")
        let report = try await service.fold(FoldOptions(posture: .closed), in: &ctx)
        #expect(route.applied.withLock { $0 }.isEmpty)
        #expect(report.already && report.verified && report.route == nil)
        #expect(report.text == "posture: closed (0°)  display: cover  orientation: portrait  (already there, nothing sent)")
    }

    @Test func aPoseLineFromBeforeTheSendDoesNotVerify() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        // The only 180° line is from an hour before the clock's start, so it is older than the send.
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"),
                               after: "devicectl-displays-open.json", afterLines: line("2026-10-17 18:00:00.000", "180.0", "openFlat"))
        let report = try await service.fold(FoldOptions(posture: .open), in: &ctx)
        #expect(!report.verified && report.posture == "open or half" && report.display == "inner")
        #expect(report.text.hasSuffix("unverified: the display agrees but no DCMPose line confirmed it"))
    }

    @Test func openFromHalfWaitsForTheHingeLineNotTheDisplay() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        // Half open: the inner display is already active before the send, so only the 180° line can verify `open`.
        let open = Fixture.string("devicectl-displays-open.json")
        worktree.runner.stub(["xcrun", "devicectl", "device", "info", "displays"], stdout: open)
        worktree.runner.stub(["xcrun", "simctl", "spawn"]) { invocation in
            ProcessOutput(stdout: invocation.arguments.contains("boot")
                ? self.line("2026-10-17 18:40:00.000", "90.0", "partiallyOpen")
                : self.line("2026-10-17 18:40:00.000", "90.0", "partiallyOpen") + self.line("2026-10-17 20:00:01.000", "180.0", "openFlat"))
        }
        let report = try await service.fold(FoldOptions(posture: .open), in: &ctx)
        #expect(route.applied.withLock { $0 } == [.hinge(degrees: 180)])
        #expect(report.verified && report.posture == "open" && report.angle == 180)
    }

    @Test func anAngleIsVerifiedByItsOwnLine() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"),
                               after: "devicectl-displays-open.json", afterLines: line("2026-10-17 20:00:01.000", "120.0", "partiallyOpen"))
        let report = try await service.fold(FoldOptions(degrees: 120), in: &ctx)
        #expect(route.applied.withLock { $0 } == [.hinge(degrees: 120)])
        #expect(report.verified && report.angle == 120 && report.posture == "half")
    }

    /// What asking a clone that stays closed to open through `route` throws.
    func openingAClosedClone(through route: FakeRoute) async throws -> XcdError? {
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"),
                               after: "devicectl-displays-closed.json", afterLines: "")
        return await #expect(throws: XcdError.self) { try await service.fold(FoldOptions(posture: .open), in: &ctx) }
    }

    @Test func aDisplayThatNeverAgreesIsPostureFailed() async throws {
        defer { worktree.remove() }
        let error = try await openingAClosedClone(through: FakeRoute())
        #expect(error?.code == .postureFailed)
        #expect(error?.message == "the simulator did not show the hinge at 180° within 5.0s")
        #expect(error?.next == "run `xcd sim fold` to see the posture it is in, then `xcd doctor`")
        #expect(error?.details == ["seen: display cover, orientation portrait"])
    }

    @Test func anUnavailableRouteIsPostureFailedWithItsReason() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        route.state.withLock { $0 = .unavailable("direct route, libxpc: xpc_connection_enable_sim2host_4sim is missing on this macOS; this needs an xcd change") }
        let error = try await openingAClosedClone(through: route)
        #expect(error?.code == .postureFailed)
        #expect(error?.message == "no route can reach the simulator's pose pipeline")
        #expect(error?.details.first?.hasPrefix("direct: ") == true)
    }

    @Test func aRouteThatFailsAtAStepIsPostureFailedNamingTheStep() async throws {
        defer { worktree.remove() }
        final class FailingRoute: PostureRoute, Sendable {
            let id = PostureRouteID.direct
            func availability(_ ctx: PostureContext) -> RouteAvailability { .available }
            func apply<Result: Sendable>(_ request: PostureRequest, _ ctx: PostureContext,
                                         holdingUntil witness: () async throws -> Result) async throws -> Result {
                throw VendorEventError(step: "lookup com.apple.coredevice.feature.remote.hid.vendordefined", detail: "no port; is the clone booted?")
            }
        }
        var (service, ctx) = try setup(routes: [FailingRoute()])
        try stubDisplays("devicectl-displays-closed.json")
        worktree.runner.stub(["xcrun", "simctl", "spawn"], stdout: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"))
        let error = await #expect(throws: XcdError.self) { try await service.fold(FoldOptions(posture: .open), in: &ctx) }
        #expect(error?.code == .postureFailed)
        #expect(error?.message == "the direct route failed at lookup com.apple.coredevice.feature.remote.hid.vendordefined")
        #expect(error?.details == ["no port; is the clone booted?"])
    }

    @Test func withoutAMatchingRecipeNothingIsSent() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try FileManager.default.removeItem(atPath: worktree.root + "/home/posture-recipes.json")   // the built-in needs 27.1
        try stubDisplays("devicectl-displays-closed.json")
        worktree.runner.stub(["xcrun", "simctl", "spawn"], stdout: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"))
        let error = await #expect(throws: XcdError.self) { try await service.fold(FoldOptions(posture: .open), in: &ctx) }
        #expect(error?.code == .postureFailed)
        #expect(error?.message == "no posture recipe matches Xcode 27.0 (27A266a) and iOS 27.0")
        #expect(error?.next == "add a `direct` entry for them to \(worktree.root)/home/posture-recipes.json")
        #expect(route.applied.withLock { $0 }.isEmpty)
    }
}
