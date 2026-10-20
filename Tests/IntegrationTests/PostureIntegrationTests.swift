import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"

/// The direct route on a real iPhone Duo. Needs Xcode 27.1 and an iOS 27.1 runtime; when
/// the Mac has no Duo it records that and passes. Never run with the other integration suites at once. The fresh
/// clone shows the Home Screen, which does not turn on the closed Duo's cover, so a turn is verified by SpringBoard's
/// orientation update, not by what the screen shows.
@Suite(.enabled(if: enabled, "set XCD_INTEGRATION=1 to run (needs Xcode 27.1, the iOS 27.1 runtime, and the iPhone Duo)"), .serialized)
struct PostureIntegrationTests {
    let runner = SystemProcessRunner()

    /// The Duo's device type when an available runtime supports it.
    func duoType() async throws -> SimDeviceType? {
        let catalog = try await SimctlClient(runner: runner, developerDir: nil).catalog()
        guard let duo = catalog.deviceTypes.first(where: { $0.identifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo" }),
              catalog.runtimes.contains(where: { $0.isAvailable && $0.supports(duo) }) else { return nil }
        return duo
    }

    func project(duo: SimDeviceType) async throws -> TempProject {
        try TempProject.make(config: """
        version: 1
        project: SampleApp.xcodeproj
        defaultDevice: duo
        devices:
          duo: { type: "\(duo.name)" }
          iphone: { type: "\(try await firstIPhoneType(runner).name)" }
        """, name: "Fold App \(UUID().uuidString.prefix(6))", fixture: repoRoot + "/Fixtures/SampleApp", parent: testsHome)
    }

    let ui = UIOptions(device: nil, bundle: nil, system: false, role: nil, index: nil, timeout: .seconds(2))

    /// Rotates, recovering once from a turn SpringBoard drops: on `posture_failed` it turns to the
    /// orientation that is neither the target nor the one the device shows, then to the target, and returns that report.
    func rotate(_ orientation: String, _ svc: Services, in ctx: inout WorktreeContext) async throws -> UIActionReport {
        do {
            return try await svc.posture.rotate(orientation, ui, in: &ctx)
        } catch let error as XcdError where error.code == .postureFailed {
            let shown = try await svc.posture.fold(FoldOptions(), in: &ctx).orientation
            let other = ["landscape-left", "landscape-right", "portrait"].first { $0 != orientation && $0 != shown } ?? "portrait"
            print("PostureIntegrationTests: the simulator dropped the turn to \(orientation); recovering via \(other)")
            _ = try await svc.posture.rotate(other, ui, in: &ctx)
            return try await svc.posture.rotate(orientation, ui, in: &ctx)
        }
    }

    @Test(.timeLimit(.minutes(10))) func foldsRotatesInBothPosturesAndRefusesAPhone() async throws {
        guard let duo = try await duoType() else {
            print("PostureIntegrationTests: no iPhone Duo with an available runtime on this Mac; nothing to test")
            return
        }
        try await withCleanup(try await project(duo: duo)) { svc in
            var ctx = try await svc.open(worktree: nil)
            let read = try await svc.posture.fold(FoldOptions(), in: &ctx)
            #expect(read.posture == "closed" && read.display == "cover" && read.route == nil)

            let open = try await svc.posture.fold(FoldOptions(posture: .open), in: &ctx)
            #expect(open.posture == "open" && open.angle == 180 && open.display == "inner" && open.verified && open.route == "direct")
            let half = try await svc.posture.fold(FoldOptions(posture: .half), in: &ctx)
            #expect(half.posture == "half" && half.angle == 90 && half.verified)
            let again = try await svc.posture.fold(FoldOptions(posture: .half), in: &ctx)
            #expect(again.already && again.route == nil)
            // From 90° SpringBoard writes no line for 120°; the hinge did move, so the display agrees.
            let angle = try await svc.posture.fold(FoldOptions(degrees: 120), in: &ctx)
            #expect(angle.display == "inner" && !angle.verified)

            let turned = try await rotate("landscape-right", svc, in: &ctx)
            #expect(turned.text.hasPrefix("rotated to landscape-right") && !turned.notes.contains { $0.hasPrefix("unverified") })
            let openTurned = try await svc.posture.fold(FoldOptions(), in: &ctx)
            #expect(openTurned.orientation == "landscape-right" && openTurned.display == "inner")
            _ = try await rotate("portrait", svc, in: &ctx)

            let closed = try await svc.posture.fold(FoldOptions(posture: .closed), in: &ctx)
            #expect(closed.posture == "closed" && closed.display == "cover" && closed.verified)
            let closedTurned = try await rotate("landscape-left", svc, in: &ctx)
            #expect(closedTurned.text.hasPrefix("rotated to landscape-left"))
            #expect(try await svc.posture.fold(FoldOptions(), in: &ctx).orientation == "landscape-left")
            _ = try await rotate("portrait", svc, in: &ctx)
            #expect(try await svc.posture.fold(FoldOptions(), in: &ctx).orientation == "portrait")

            let upside = await #expect(throws: XcdError.self) { try await rotate("portrait-upside-down", svc, in: &ctx) }
            #expect(upside?.code == .platformUnsupported)
            let phone = await #expect(throws: XcdError.self) { try await svc.posture.fold(FoldOptions(device: "iphone"), in: &ctx) }
            #expect(phone?.code == .platformUnsupported && phone?.next == "pass --device duo")
        }
    }
}
