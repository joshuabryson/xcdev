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

    /// Before the send devicectl says `from` (closed unless given) and the log the given line; after it, devicectl says
    /// `after` and the log `afterLines`.
    func stubBeforeAndAfter(_ route: FakeRoute, before: String, after: String, afterLines: String,
                            from: String = "devicectl-displays-closed.json") throws {
        let earlier = Fixture.string(from)
        let later = Fixture.string(after)
        worktree.runner.stub(["xcrun", "devicectl", "device", "info", "displays"]) { _ in
            ProcessOutput(stdout: route.sent.withLock { $0 } ? later : earlier)
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

    /// SpringBoard logs its own angle, not the one sent: 120° from closed is 118.3°. That is not
    /// within 1°, so it is unverified, and the report gives the angle the simulator shows.
    @Test func anAngleTheSimulatorRoundsIsUnverifiedWithTheAngleItShows() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"),
                               after: "devicectl-displays-open.json", afterLines: line("2026-10-17 20:00:01.000", "118.3", "partiallyOpen"))
        let report = try await service.fold(FoldOptions(degrees: 120), in: &ctx)
        #expect(!report.verified && report.posture == "half" && report.angle == 118.3)
        #expect(report.text.hasPrefix("posture: half (118°)  display: inner"))
    }

    /// From open, the cover comes on after the send and no line follows: that proves 0°, and no other angle.
    @Test(arguments: [(FoldOptions(posture: .closed), true), (FoldOptions(degrees: 30), false)])
    func theCoverWithoutALineVerifiesOnlyZeroDegrees(options: FoldOptions, verified: Bool) async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:40:00.000", "180.0", "openFlat"),
                               after: "devicectl-displays-closed.json", afterLines: "", from: "devicectl-displays-open.json")
        let request = try #require(options.request)
        let report = try await service.fold(options, in: &ctx)
        #expect(route.applied.withLock { $0 } == [request])
        #expect(report.verified == verified)
        #expect(report.text.hasPrefix("posture: closed  display: cover  orientation: portrait  route: direct"))
    }

    /// Below 90° either display may be on, since the Duo swaps displays at 85°: the line decides.
    @Test func aSmallAngleOnTheInnerDisplayIsVerifiedByItsLine() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"),
                               after: "devicectl-displays-open.json", afterLines: line("2026-10-17 20:00:01.000", "30.0", "partiallyOpen"))
        let report = try await service.fold(FoldOptions(degrees: 30), in: &ctx)
        #expect(report.verified && report.angle == 30 && report.display == "inner")
    }

    /// At 60° the Duo keeps the cover on, and SpringBoard's line says 61.7° `closed`: the display
    /// agrees, the line is not within 1°, so it is unverified rather than `posture_failed`.
    @Test func sixtyDegreesOnTheCoverIsUnverifiedNotPostureFailed() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"),
                               after: "devicectl-displays-closed.json", afterLines: line("2026-10-17 20:00:01.000", "61.7", "closed"))
        let report = try await service.fold(FoldOptions(degrees: 60), in: &ctx)
        #expect(route.applied.withLock { $0 } == [.hinge(degrees: 60)])
        #expect(!report.verified && report.display == "cover" && report.angle == 61.7)
    }

    /// The hinge's display rule: the cover at 0°, the inner display from 90°, either one between.
    @Test func theDisplayRuleFollowsTheDuosSwapAt85Degrees() {
        let cover = DisplaysRead(innerActive: false, deviceOrientation: "portrait")
        let inner = DisplaysRead(innerActive: true, deviceOrientation: "landscapeRight")
        #expect(PostureReader.displaysAgree(.hinge(degrees: 0), cover) && !PostureReader.displaysAgree(.hinge(degrees: 0), inner))
        #expect(PostureReader.displaysAgree(.hinge(degrees: 89), cover) && PostureReader.displaysAgree(.hinge(degrees: 89), inner))
        #expect(!PostureReader.displaysAgree(.hinge(degrees: 90), cover) && PostureReader.displaysAgree(.hinge(degrees: 90), inner))
    }

    /// A line newer than the send verifies `open` only within 1° of 180°; the inner display is on in every case.
    @Test(arguments: [(179.0, true), (178.0, false), (90.0, false)])
    func aLineVerifiesOpenOnlyWithinOneDegree(degrees: Double, verified: Bool) async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"), after: "devicectl-displays-open.json",
                               afterLines: line("2026-10-17 20:00:01.000", String(degrees), Posture.nearest(degrees).springBoardState))
        let report = try await service.fold(FoldOptions(posture: .open), in: &ctx)
        #expect(report.verified == verified && report.display == "inner")
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

    let uiOptions = UIOptions(device: nil, bundle: nil, system: false, role: nil, index: nil, timeout: .seconds(2))

    @Test func rotateOnAFoldableGoesThroughTheRouteAndIsVerifiedByDevicectl() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"),
                               after: "devicectl-displays-closed.json", afterLines: "")
        // Later stubs win: once the route has sent, devicectl reports the cover turned to landscapeLeft.
        let closed = Fixture.string("devicectl-displays-closed.json")
        let turned = closed.replacingOccurrences(of: "\"portrait\"", with: "\"landscapeLeft\"")
        worktree.runner.stub(["xcrun", "devicectl", "device", "info", "displays"]) { _ in
            ProcessOutput(stdout: route.sent.withLock { $0 } ? turned : closed)
        }
        let report = try await service.rotate("landscape-left", uiOptions, in: &ctx)
        #expect(route.applied.withLock { $0 } == [.orientation(.landscapeLeft)])
        #expect(report.action == "rotated to" && report.target == "landscape-left" && report.device == "duo")
        #expect(report.text.hasPrefix("rotated to landscape-left  "))
        #expect(report.notes == ["via the pose pipeline (foldable): posture closed, display cover"])
        let again = try await service.rotate("landscape-left", uiOptions, in: &ctx)
        #expect(route.applied.withLock { $0 }.count == 1)
        #expect(again.notes == ["via the pose pipeline (foldable): posture closed, display cover", "already in that orientation; nothing sent"])
    }

    @Test func rotateRefusesUpsideDownAndBadWordsOnAFoldable() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubDisplays("devicectl-displays-closed.json")
        worktree.runner.stub(["xcrun", "simctl", "spawn"], stdout: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"))
        let upside = await #expect(throws: XcdError.self) { try await service.rotate("portrait-upside-down", uiOptions, in: &ctx) }
        #expect(upside?.code == .platformUnsupported)
        #expect(upside?.next == "use one of: landscape-left, landscape-right, portrait")
        let word = await #expect(throws: XcdError.self) { try await service.rotate("sideways", uiOptions, in: &ctx) }
        #expect(word?.code == .usage && word?.next == "use one of: portrait, portrait-upside-down, landscape-left, landscape-right")
        #expect(route.applied.withLock { $0 }.isEmpty)
    }

    @Test func aRotationTheDisplayNeverShowsIsPostureFailed() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"),
                               after: "devicectl-displays-closed.json", afterLines: "")
        let error = await #expect(throws: XcdError.self) { try await service.rotate("landscape-left", uiOptions, in: &ctx) }
        #expect(error?.code == .postureFailed)
        #expect(error?.message == "the simulator did not show the landscape-left orientation within 5.0s")
        #expect(error?.next == "run `xcd sim fold` to see the posture it is in, then rotate to another orientation and back: the simulator sometimes drops a turn")
        #expect(error?.details == ["seen: display cover, orientation portrait"])
    }
}
