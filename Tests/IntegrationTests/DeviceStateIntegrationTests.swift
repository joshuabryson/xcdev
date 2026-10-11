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
            do {
                try await Task.sleep(for: .seconds(3))
                let stopped = try await svc.media.stopRecording(device: nil, in: ctx)
                #expect(stopped.outcome == .stopped && (stopped.bytes ?? 0) > 0, "\(stopped)")
                let asset = AVURLAsset(url: URL(fileURLWithPath: try #require(started.path)))
                #expect(try await asset.load(.duration).seconds > 1)

                _ = try await svc.deviceState.statusBar(StatusBarOverrides(time: "9:41", batteryLevel: 100), device: nil, in: &ctx)
                _ = try await svc.deviceState.appearance(.dark, device: nil, in: &ctx)
                _ = try await svc.deviceState.location(Coordinate(latitude: 37.33, longitude: -122.03), device: nil, in: &ctx)
                try await setsThePasteboardOrSaysThatDeviceHubHasIt(&ctx, svc)
                _ = try await svc.deviceState.openURL("https://example.com", device: nil, in: &ctx)
                _ = try await svc.deviceState.privacy(.reset, service: "all", bundle: nil, device: nil, in: &ctx)
                _ = try await svc.deviceState.addMedia([shot.path], device: nil, in: &ctx)
                _ = try await svc.deviceState.statusBar(nil, device: nil, in: &ctx)
            } catch {
                // A failed step must not leave a recorder running.
                _ = await Recordings.stopAll(in: ctx.paths, detached: svc.detached, now: Date())
                throw error
            }
        }
    }

    /// Device Hub starts syncing the Mac's clipboard with a simulator some tens of seconds after it boots, and from then
    /// on the simulator drops text from simctl, which exits 0 all the same. So with Device Hub open the
    /// text is set until it stops being kept, for up to two minutes, and then the failure has to say why. What the
    /// pasteboard holds is never printed here: once the sync has started it is what the person at the Mac copied.
    func setsThePasteboardOrSaysThatDeviceHubHasIt(_ ctx: inout WorktreeContext, _ svc: Services) async throws {
        let deviceHub = try await runner.run(Invocation("/usr/bin/pgrep", ["-x", SimctlClient.deviceHubProcess])).succeeded
        let deadline = Date().addingTimeInterval(deviceHub ? 120 : 0)
        var kept = 0
        repeat {
            let text = "hello pasteboard \(kept)"
            do {
                _ = try await svc.deviceState.setPasteboard(text: text, device: nil, in: &ctx)
            } catch let error as XcdError {
                #expect(deviceHub, "the text was not kept, and Device Hub is not running: \(error)")
                #expect(error.code == .simulatorFailed && error.message == "simctl reported success, but iphone's pasteboard does not hold the text")
                #expect(error.next?.hasPrefix("Device Hub is open") == deviceHub, "\(error.next ?? "")")
                return
            }
            kept += 1
            if !deviceHub {
                let roundTripped = try await svc.deviceState.pasteboard(device: nil, in: &ctx).text == text
                #expect(roundTripped, "the pasteboard does not hold the text that was reported as set")
            }
            if Date() < deadline { try await Task.sleep(for: .seconds(3)) }
        } while Date() < deadline
    }

    @Test(.timeLimit(.minutes(10))) func aRecordingSurvivesItsStarterAndShutdownFinishesIt() async throws {
        try await withCleanup(try await project()) { svc in
            var ctx = try await svc.open(worktree: nil)
            let started = try await svc.media.startRecording(device: nil, out: "clip.mov", in: &ctx)
            do {
                let record = try #require(Recordings.load(ctx.paths.recordingFile(device: "iphone")))
                #expect(getsid(record.process.pid) == record.process.pid)
                try await Task.sleep(for: .seconds(2))
                let shutdown = try await svc.provisioner.shutdownReport(nil, in: ctx, detached: svc.detached)
                #expect(shutdown.notes.count == 1)
                #expect(!svc.detached.inspector.isRunning(record.process))
                let size = (try FileManager.default.attributesOfItem(atPath: try #require(started.path))[.size] as? NSNumber)?.int64Value
                #expect((size ?? 0) > 0)
            } catch {
                // A failed step must not leave a recorder running.
                _ = await Recordings.stopAll(in: ctx.paths, detached: svc.detached, now: Date())
                throw error
            }
        }
    }
}
