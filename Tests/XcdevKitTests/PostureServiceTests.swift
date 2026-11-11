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

    /// A display transition's `COMPLETED:` line, with the displays as SpringBoard writes them (`.cover:aux .inner:pri`).
    func completed(_ time: String, _ displays: String, _ degrees: String, _ state: String) -> String {
        "\(time) Df SpringBoard[88269:1063c187] [com.apple.SpringBoard:DisplayContentMode] COMPLETED:     \(displays) | \(degrees)° (0.00 fold:0.00): \(state) [device:Pu]\n"
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
        let phone = try #require(ctx.state.devices["iphone"]?.udid)          // provisioned, never booted
        #expect(!worktree.runner.commandLines.contains { $0.contains("simctl boot") && $0.contains(phone) })
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
        #expect(report.text.hasSuffix("  unverified: the simulator did not report the requested angle within 5s"))
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

    /// SpringBoard logs its own angle, not the one sent: 120° from closed is 118.3°. That is within 3°, so it is
    /// verified, and the report gives the angle the simulator shows.
    @Test func anAngleTheSimulatorRoundsIsVerifiedWithTheAngleItShows() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"),
                               after: "devicectl-displays-open.json", afterLines: line("2026-10-17 20:00:01.000", "118.3", "partiallyOpen"))
        let report = try await service.fold(FoldOptions(degrees: 120), in: &ctx)
        #expect(report.verified && report.posture == "half" && report.angle == 118.3)
        #expect(report.text.hasPrefix("posture: half (118°)  display: inner"))
    }

    /// iOS 27.2 leaves the hinge 2.6° past a half fold: from open SpringBoard's last line says 87.4°, which is the
    /// half fold, verified with the angle shown. The angles and states are an iOS 27.2 Duo clone's, 2026-11-11.
    @Test func aHalfFoldThatStopsPastNinetyDegreesIsVerified() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        let lines = line("2026-10-17 20:00:01.000", "174.0", "partiallyOpen+toClosed")
            + line("2026-10-17 20:00:01.900", "87.4", "partiallyOpen+foldAvoidance")
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:40:00.000", "180.0", "openFlat"),
                               after: "devicectl-displays-open.json", afterLines: lines, from: "devicectl-displays-open.json")
        let report = try await service.fold(FoldOptions(posture: .half), in: &ctx)
        #expect(route.applied.withLock { $0 } == [.hinge(degrees: 90)])
        #expect(report.verified && report.posture == "half" && report.angle == 87.4)
        #expect(report.text.hasPrefix("posture: half (87°)  display: inner"))
    }

    /// devicectl can say the cover is on for seconds after SpringBoard has completed the switch to the inner display:
    /// a `COMPLETED:` line newer than the send stands for it. On an iOS 27.2 Duo clone, 2026-11-11, devicectl still
    /// said cover 3.6 s after this switch.
    @Test func aCompletedSwitchAfterTheSendVerifiesOpenWhileDevicectlStillSaysCover() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        let lines = line("2026-10-17 20:00:01.000", "12.3", "closed+toOpen")
            + completed("2026-10-17 20:00:01.600", ".cover:aux .inner:pri", "180.0", "openFlat")
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"),
                               after: "devicectl-displays-closed.json", afterLines: lines)
        let report = try await service.fold(FoldOptions(posture: .open), in: &ctx)
        #expect(report.verified && report.posture == "open" && report.angle == 180 && report.display == "inner", "\(report.text)")
    }

    /// Only a switch completed after the send counts: an older one says nothing about this request.
    @Test func aCompletedSwitchFromBeforeTheSendDoesNotVerify() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"), after: "devicectl-displays-closed.json",
                               afterLines: completed("2026-10-17 18:50:00.000", ".cover:aux .inner:pri", "180.0", "openFlat"))
        let error = await #expect(throws: XcdError.self) { try await service.fold(FoldOptions(posture: .open), in: &ctx) }
        #expect(error?.code == .postureFailed && error?.details == ["seen: display cover, screen portrait"])
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

    /// A hinge request turns nothing, so `closed` from open reports the orientation of the read before the send (the
    /// boot's last update, landscape-left), not devicectl's word, which is the closed Home Screen's and stays portrait
    ///. 0° from the inner display reads no log, so there is no newer update to take.
    @Test func closedReportsTheOrientationOfTheReadBeforeTheSendNotTheScreens() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:40:00.000", "180.0", "openFlat") + update("2026-10-17 18:41:00.000", "landscapeLeft"),
                               after: "devicectl-displays-closed.json", afterLines: "", from: "devicectl-displays-open.json")
        let report = try await service.fold(FoldOptions(posture: .closed), in: &ctx)
        #expect(route.applied.withLock { $0 } == [.hinge(degrees: 0)])
        #expect(report.verified && report.posture == "closed" && report.orientation == "landscape-left")
    }

    /// `open` from closed: an update newer than the send names the orientation; without one the read before the send
    /// does, while devicectl's open word (`landscapeRight`, the quarter-turned screen) would map to portrait.
    @Test(arguments: [("", "landscape-left"), ("portrait", "portrait")])
    func openTakesTheUpdateAfterTheSendElseTheOrientationOfTheReadBefore(word: String, orientation: String) async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        let opened = line("2026-10-17 20:00:01.000", "180.0", "openFlat") + (word.isEmpty ? "" : update("2026-10-17 20:00:01.500", word))
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed") + update("2026-10-17 18:34:00.000", "landscapeLeft"),
                               after: "devicectl-displays-open.json", afterLines: opened)
        let report = try await service.fold(FoldOptions(posture: .open), in: &ctx)
        #expect(report.verified && report.posture == "open" && report.orientation == orientation)
    }

    /// The cover stays on up to 85°, so a cover that was already on proves nothing about 0°: from
    /// 61.7° `closed` is sent, and only a hinge line within 1° of 0° newer than the send verifies it; none is
    /// `verified: false`, not `posture_failed`, since the display cannot disagree.
    @Test(arguments: [("", false), ("0.0", true)])
    func aCoverThatWasAlreadyOnVerifiesZeroDegreesOnlyByItsLine(degrees: String, verified: Bool) async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "61.7", "closed"), after: "devicectl-displays-closed.json",
                               afterLines: degrees.isEmpty ? "" : line("2026-10-17 20:00:01.000", degrees, "fullyClosed"))
        let report = try await service.fold(FoldOptions(posture: .closed), in: &ctx)
        #expect(route.applied.withLock { $0 } == [.hinge(degrees: 0)])
        #expect(report.verified == verified && report.display == "cover" && report.angle == (verified ? 0 : nil))
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

    /// At 60° the Duo keeps the cover on, and SpringBoard's line says 61.7° `closed`: the display agrees and the line
    /// is within 3°, so it is verified. At 50° the same line is not, so it is unverified rather than `posture_failed`.
    @Test(arguments: [(60.0, true), (50.0, false)])
    func anAngleOnTheCoverIsVerifiedByItsLineAndNeverPostureFailed(degrees: Double, verified: Bool) async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"),
                               after: "devicectl-displays-closed.json", afterLines: line("2026-10-17 20:00:01.000", "61.7", "closed"))
        let report = try await service.fold(FoldOptions(degrees: degrees), in: &ctx)
        #expect(route.applied.withLock { $0 } == [.hinge(degrees: degrees)])
        #expect(report.verified == verified && report.display == "cover" && report.angle == 61.7)
    }

    /// The hinge's display rule: the cover at 0°, the inner display from 90°, either one between.
    @Test func theDisplayRuleFollowsTheDuosSwapAt85Degrees() {
        let cover = DisplaysRead(innerActive: false, deviceOrientation: "portrait")
        let inner = DisplaysRead(innerActive: true, deviceOrientation: "landscapeRight")
        #expect(PostureReader.displaysAgree(.hinge(degrees: 0), cover) && !PostureReader.displaysAgree(.hinge(degrees: 0), inner))
        #expect(PostureReader.displaysAgree(.hinge(degrees: 89), cover) && PostureReader.displaysAgree(.hinge(degrees: 89), inner))
        #expect(!PostureReader.displaysAgree(.hinge(degrees: 90), cover) && PostureReader.displaysAgree(.hinge(degrees: 90), inner))
    }

    /// The cover alone suffices for 0° only when the inner display was active before the send; never
    /// for another angle or a turn.
    @Test func theCoverSufficesForZeroDegreesOnlyWhenTheInnerDisplayWasActiveBefore() {
        let fromOpen = PostureState(innerActive: true, degrees: 180, posture: .open)
        let fromCover = PostureState(innerActive: false, degrees: 61.7)
        #expect(PostureReader.displaysSuffice(PostureChange(.hinge(degrees: 0), from: fromOpen)))
        #expect(!PostureReader.displaysSuffice(PostureChange(.hinge(degrees: 0), from: fromCover)))
        #expect(!PostureReader.displaysSuffice(PostureChange(.hinge(degrees: 30), from: fromOpen)))
        #expect(!PostureReader.displaysSuffice(PostureChange(.orientation(.portrait), from: fromOpen)))
    }

    /// A line newer than the send verifies `open` only within 3° of 180°; the inner display is on in every case, and
    /// the report gives the line's angle either way.
    @Test(arguments: [(177.0, true), (176.0, false), (90.0, false)])
    func aLineVerifiesOpenOnlyWithinThreeDegrees(degrees: Double, verified: Bool) async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed"), after: "devicectl-displays-open.json",
                               afterLines: line("2026-10-17 20:00:01.000", String(degrees), Posture.nearest(degrees).springBoardState))
        let report = try await service.fold(FoldOptions(posture: .open), in: &ctx)
        #expect(report.verified == verified && report.display == "inner" && report.angle == degrees)
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
        #expect(error?.details == ["seen: display cover, screen portrait"])
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

    /// SpringBoard's orientation update, which names the device orientation.
    func update(_ time: String, _ word: String) -> String {
        let number = ["portrait": 1, "portraitUpsideDown": 2, "landscapeLeft": 3, "landscapeRight": 4][word] ?? 0
        return "\(time) Df SpringBoard[88269:1063c187] [com.apple.SpringBoard:DeviceOrientationUpdateDeferral] Updated device orientation update to: \(word) (\(number)) animated: YES for reason: Device pose changed\n"
    }

    /// devicectl says `screen`, or `turnedScreen` once the route has sent; every log read says `beforeLog` until the route
    /// sends and `afterLog` after it.
    func stubTurn(_ route: FakeRoute, screen: String, turnedScreen: String? = nil, beforeLog: String, afterLog: String) {
        worktree.runner.stub(["xcrun", "devicectl", "device", "info", "displays"]) { _ in
            ProcessOutput(stdout: route.sent.withLock { $0 } ? (turnedScreen ?? screen) : screen)
        }
        worktree.runner.stub(["xcrun", "simctl", "spawn"]) { _ in
            ProcessOutput(stdout: route.sent.withLock { $0 } ? afterLog : beforeLog)
        }
    }

    /// The fresh clone's case: the closed Home Screen never turns, so devicectl keeps saying portrait, and SpringBoard's
    /// update after the send verifies the turn.
    @Test func rotateOnAFoldableIsVerifiedBySpringBoardsUpdateWhileTheScreenStaysPortrait() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        let closedLine = line("2026-10-17 18:33:20.000", "0.0", "fullyClosed")
        stubTurn(route, screen: Fixture.string("devicectl-displays-closed.json"), beforeLog: closedLine,
                 afterLog: closedLine + update("2026-10-17 20:00:01.000", "landscapeLeft"))
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

    /// A turn SpringBoard drops writes no orientation update: `posture_failed`, never unverified.
    @Test func aRotationWithoutAnOrientationUpdateIsPostureFailed() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        let closedLine = line("2026-10-17 18:33:20.000", "0.0", "fullyClosed")
        stubTurn(route, screen: Fixture.string("devicectl-displays-closed.json"), beforeLog: closedLine, afterLog: closedLine)
        let error = await #expect(throws: XcdError.self) { try await service.rotate("landscape-left", uiOptions, in: &ctx) }
        #expect(error?.code == .postureFailed)
        #expect(error?.message == "the simulator did not show the landscape-left orientation within 5.0s")
        #expect(error?.next == "run `xcd sim fold` to see the posture it is in, wait a few seconds, then rotate to another orientation and back: the simulator sometimes drops a turn")
        #expect(error?.details == ["seen: no orientation update; screen portrait"])
    }

    /// An update from before the send that names the orientation asked for does not verify the turn.
    @Test func anOrientationUpdateFromBeforeTheSendDoesNotVerifyATurn() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        try stubBeforeAndAfter(route, before: line("2026-10-17 18:33:20.000", "0.0", "fullyClosed") + update("2026-10-17 18:33:21.000", "portrait"),
                               after: "devicectl-displays-closed.json", afterLines: update("2026-10-17 18:00:00.000", "landscapeLeft"))
        let error = await #expect(throws: XcdError.self) { try await service.rotate("landscape-left", uiOptions, in: &ctx) }
        #expect(error?.code == .postureFailed && route.applied.withLock { $0 } == [.orientation(.landscapeLeft)])
    }

    /// The already-check reads the device orientation from the last update of the boot, not the screen: devicectl says
    /// portrait, the device is in landscape-left, so nothing is sent.
    @Test func alreadyIsTheLastOrientationUpdateNotTheScreen() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        let log = line("2026-10-17 18:33:20.000", "0.0", "fullyClosed") + update("2026-10-17 18:34:00.000", "landscapeLeft")
        stubTurn(route, screen: Fixture.string("devicectl-displays-closed.json"), beforeLog: log, afterLog: log)
        let report = try await service.rotate("landscape-left", uiOptions, in: &ctx)
        #expect(route.applied.withLock { $0 }.isEmpty)
        #expect(report.notes == ["via the pose pipeline (foldable): posture closed, display cover", "already in that orientation; nothing sent"])
    }

    /// While open, devicectl's word is turned a quarter (`portrait` for the pose landscape-left) and SpringBoard's update
    /// names the device's own orientation, which verifies the turn as it is. A turn moves no hinge,
    /// so the note keeps the posture read before the send (`open`, not the display's `open or half`) when no hinge
    /// line follows.
    @Test func anOpenTurnIsVerifiedByThePlainWordWhileTheScreenSaysTheQuarterTurnedOne() async throws {
        defer { worktree.remove() }
        let route = FakeRoute()
        var (service, ctx) = try setup(routes: [route])
        let open = Fixture.string("devicectl-displays-open.json")
        let openLine = line("2026-10-17 18:40:00.000", "180.0", "openFlat")
        stubTurn(route, screen: open, turnedScreen: open.replacingOccurrences(of: "\"landscapeRight\"", with: "\"portrait\""),
                 beforeLog: openLine, afterLog: openLine + update("2026-10-17 20:00:01.000", "landscapeLeft"))
        let report = try await service.rotate("landscape-left", uiOptions, in: &ctx)
        #expect(route.applied.withLock { $0 } == [.orientation(.landscapeLeft)])
        #expect(report.text.hasPrefix("rotated to landscape-left  "))
        #expect(report.notes == ["via the pose pipeline (foldable): posture open, display inner"])
    }
}
