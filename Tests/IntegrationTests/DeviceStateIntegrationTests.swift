import AVFoundation
import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"

@Suite(.enabled(if: enabled, "set XCD_INTEGRATION=1 to run (needs Xcode + an iOS simulator runtime)"), .serialized)
struct DeviceStateIntegrationTests {
    let runner = SystemProcessRunner()

    /// The first iPhone type an installed iOS runtime supports, and the screen scale its profile reports.
    func phoneType() async throws -> (name: String, scale: Double) {
        let catalog = try await SimctlClient(runner: runner, developerDir: nil).catalog()
        let phone = try #require(catalog.deviceTypes.first { type in
            type.productFamily == "iPhone" && catalog.runtimes.contains { $0.isAvailable && $0.platform == "iOS" && $0.supports(type) }
        }, "no iPhone simulator runtime installed")
        let scale = try #require(phone.bundlePath.flatMap(DeviceTypeProfile.scale(bundlePath:)), "no screen scale for \(phone.name)")
        return (phone.name, scale)
    }

    func project() async throws -> TempProject {
        try TempProject.make(config: """
        version: 1
        project: SampleApp.xcodeproj
        defaultDevice: iphone
        devices:
          iphone: { type: "\(try await phoneType().name)" }
        """, name: "Media App \(UUID().uuidString.prefix(6))", fixture: repoRoot + "/Fixtures/SampleApp", parent: testsHome)
    }

    /// `simctl openurl` launches Safari, which on a freshly booted clone sometimes times out (exit 60, "Operation timed
    /// out"); that is the simulator being slow, so retry it once. Any other failure is real.
    func openURLRetryingTimeouts(_ svc: Services, _ ctx: inout WorktreeContext) async throws {
        do {
            _ = try await svc.deviceState.openURL("https://example.com", device: nil, in: &ctx)
        } catch let error as XcdError where error.details.contains("exit: 60") {
            _ = try await svc.deviceState.openURL("https://example.com", device: nil, in: &ctx)
        }
    }

    @Test(.timeLimit(.minutes(10))) func screenshotsRecordingsAndDeviceState() async throws {
        let expectedScale = try await phoneType().scale
        try await withCleanup(try await project()) { svc in
            var ctx = try await svc.open(worktree: nil)
            let shot = try await svc.media.screenshot(device: nil, out: nil, in: &ctx)
            #expect(shot.path.hasPrefix(ctx.location.projectRoot + "/.xcdev-media/main/main/"))
            #expect((shot.width ?? 0) > 0 && (shot.height ?? 0) > (shot.width ?? 0))
            #expect(shot.scale == expectedScale)
            #expect(try String(contentsOfFile: ctx.location.projectRoot + "/.gitignore", encoding: .utf8).contains(".xcdev-media/"))

            let started = try await svc.media.startRecording(device: nil, out: nil, in: &ctx)
            try await Task.sleep(for: .seconds(3))
            let stopped = try await svc.media.stopRecording(device: nil, in: ctx)
            #expect(stopped.outcome == .stopped && (stopped.bytes ?? 0) > 0, "\(stopped)")
            let asset = AVURLAsset(url: URL(fileURLWithPath: try #require(started.path)))
            #expect(try await asset.load(.duration).seconds > 1)

            _ = try await svc.deviceState.statusBar(StatusBarOverrides(time: "9:41", batteryLevel: 100), device: nil, in: &ctx)
            _ = try await svc.deviceState.appearance(.dark, device: nil, in: &ctx)
            _ = try await svc.deviceState.location(Coordinate(latitude: 37.33, longitude: -122.03), device: nil, in: &ctx)
            _ = try await svc.deviceState.setPasteboard(text: "hello pasteboard", device: nil, in: &ctx)
            #expect(try await svc.deviceState.pasteboard(device: nil, in: &ctx).text == "hello pasteboard")
            try await openURLRetryingTimeouts(svc, &ctx)
            _ = try await svc.deviceState.privacy(.reset, service: "all", bundle: nil, device: nil, in: &ctx)
            _ = try await svc.deviceState.addMedia([shot.path], device: nil, in: &ctx)
            _ = try await svc.deviceState.statusBar(nil, device: nil, in: &ctx)
        }
    }

    @Test(.timeLimit(.minutes(10))) func aRecordingSurvivesItsStarterAndShutdownFinishesIt() async throws {
        try await withCleanup(try await project()) { svc in
            var ctx = try await svc.open(worktree: nil)
            let started = try await svc.media.startRecording(device: nil, out: "clip.mov", in: &ctx)
            let record = try #require(Recordings.load(ctx.paths.recordingFile(device: "iphone")))
            #expect(getsid(record.process.pid) == record.process.pid)
            try await Task.sleep(for: .seconds(2))
            let shutdown = try await svc.provisioner.shutdownReport(nil, in: ctx, detached: svc.detached)
            #expect(shutdown.notes.count == 1)
            #expect(!svc.detached.inspector.isRunning(record.process))
            let size = (try FileManager.default.attributesOfItem(atPath: try #require(started.path))[.size] as? NSNumber)?.int64Value
            #expect((size ?? 0) > 0)
        }
    }
}
