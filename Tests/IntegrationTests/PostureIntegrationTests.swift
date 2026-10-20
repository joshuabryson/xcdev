import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"

/// The direct route on a real iPhone Duo. Needs Xcode 27.1 and an iOS 27.1 runtime; when
/// the Mac has no Duo it records that and passes. Never run with the other integration suites at once.
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
            let angle = try await svc.posture.fold(FoldOptions(degrees: 120), in: &ctx)
            #expect(angle.angle == 120 && angle.posture == "half" && angle.verified)

            let turned = try await svc.posture.rotate("landscape-right", ui, in: &ctx)
            #expect(turned.text.hasPrefix("rotated to landscape-right") && !turned.notes.contains { $0.hasPrefix("unverified") })
            let openTurned = try await svc.posture.fold(FoldOptions(), in: &ctx)
            #expect(openTurned.orientation == "landscape-right" && openTurned.display == "inner")
            _ = try await svc.posture.rotate("portrait", ui, in: &ctx)

            let closed = try await svc.posture.fold(FoldOptions(posture: .closed), in: &ctx)
            #expect(closed.posture == "closed" && closed.display == "cover" && closed.verified)
            let closedTurned = try await svc.posture.rotate("landscape-left", ui, in: &ctx)
            #expect(closedTurned.text.hasPrefix("rotated to landscape-left"))
            #expect(try await svc.posture.fold(FoldOptions(), in: &ctx).orientation == "landscape-left")
            _ = try await svc.posture.rotate("portrait", ui, in: &ctx)
            #expect(try await svc.posture.fold(FoldOptions(), in: &ctx).orientation == "portrait")

            let upside = await #expect(throws: XcdError.self) { try await svc.posture.rotate("portrait-upside-down", ui, in: &ctx) }
            #expect(upside?.code == .platformUnsupported)
            let phone = await #expect(throws: XcdError.self) { try await svc.posture.fold(FoldOptions(device: "iphone"), in: &ctx) }
            #expect(phone?.code == .platformUnsupported && phone?.next == "pass --device duo")
        }
    }
}
