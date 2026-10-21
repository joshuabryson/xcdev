import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd ui screenshot` and `record` on a Mac.
@Suite struct MacCaptureTests {
    let worktree = FakeWorktree(prefix: "xcd mac capture")
    static let window = CapturedWindow(id: 15610, title: "Probe", frame: ScreenRect(x: 2558, y: 249, w: 900, h: 552))
    var product: AppProduct { AppProduct(path: worktree.root + "/Build/Products/Debug/Mac.app", bundleId: "dev.x.Mac", executableName: "Mac", platform: "macosx") }

    /// `api`: the app's Accessibility tree; `running`: the pids `ps` lists for the build's executable.
    func setup(_ capture: FakeWindowCapture, api: FakeAccessibility = FakeAccessibility(app: UIServiceMacTests.app), granted: Bool = true,
               locked: Bool = false, running: [Int32] = [7],
               detached: FakeDetachedProcesses = FakeDetachedProcesses()) throws -> (MediaService, WorktreeContext) {
        let ctx = try worktree.context(UIServiceMacTests.yaml, container: "App.xcodeproj")
        var state = AppState()
        state.builds["mac"] = BuildRecord(scheme: "App", configuration: nil, product: product, finishedAt: Date())
        try AppStateStore.save(state, ctx.paths)
        // SystemDetachedProcesses creates the log's folder; the fake only runs `onStart`, which writes the log.
        try FileManager.default.createDirectory(atPath: ctx.paths.logs, withIntermediateDirectories: true)
        let product = product
        worktree.runner.stub(["ps"]) { _ in ProcessOutput(stdout: running.map { "  \($0) \(product.executablePath)\n" }.joined()) }
        let service = MediaService(provisioner: worktree.provisioner, detached: detached, currentDirectory: worktree.root, sleep: Instant.sleep,
                                   capture: capture, permissions: { MacPermissions(accessibility: true, screenRecording: granted, hostApp: "iTerm") },
                                   accessibility: { api }, screenLocked: { locked }, xcdExecutable: "/usr/local/bin/xcd")
        return (service, ctx)
    }

    @Test func aScreenshotCapturesTheMainWindowAtItsScale() async throws {
        defer { worktree.remove() }
        let capture = FakeWindowCapture(window: Self.window)
        var (service, ctx) = try setup(capture)
        let report = try await service.screenshot(device: "mac", out: worktree.root + "/shot.png", in: &ctx)
        #expect(report.width == 1800 && report.height == 1104 && report.scale == 2 && report.udid == nil)
        #expect(capture.captured == [worktree.root + "/shot.png"] && report.text.contains("1800x1104px  @2x"))
    }

    /// No window in the Accessibility tree, or none ScreenCaptureKit lists under the main window's title.
    @Test func anAppWithNoWindowIsReportedNotCaptured() async throws {
        defer { worktree.remove() }
        // A hidden app with no window of its own still has AppKit's untitled one; it is never what is captured.
        let hideTime = CapturedWindow(id: 15611, title: "", frame: ScreenRect(x: 0, y: 0, w: 500, h: 500))
        let cases = [(FakeWindowCapture(window: nil), FakeAccessibility(app: UIServiceMacTests.app)),
                     (FakeWindowCapture(window: hideTime), FakeAccessibility(app: FakeApp(windows: [], hidden: true)))]
        for (capture, api) in cases {
            var (service, ctx) = try setup(capture, api: api)
            let error = await #expect(throws: XcdError.self) { try await service.screenshot(device: "mac", out: nil, in: &ctx) }
            #expect(error?.code == .elementNotFound && error?.message == "the app has no window to capture")
            #expect(error?.next?.contains("`xcd open <route>`") == true && error?.next?.contains("--show") == true)
            #expect(capture.captured.isEmpty)
        }
    }

    @Test func withoutScreenRecordingACaptureIsPermissionMissing() async throws {
        defer { worktree.remove() }
        var (service, ctx) = try setup(FakeWindowCapture(window: Self.window), granted: false)
        let error = await #expect(throws: XcdError.self) { try await service.screenshot(device: "mac", out: nil, in: &ctx) }
        #expect(error?.code == .permissionMissing && error?.message.contains("Screen Recording") == true)
    }

    /// The lock is checked before the grant and the app's process, with the words `ui` commands use.
    @Test func aLockedScreenRefusesAScreenshotBeforeTheGrantAndTheApp() async throws {
        defer { worktree.remove() }
        let capture = FakeWindowCapture(window: Self.window)
        var (service, ctx) = try setup(capture, granted: false, locked: true, running: [])
        let error = await #expect(throws: XcdError.self) { try await service.screenshot(device: "mac", out: nil, in: &ctx) }
        #expect(error == MacScreenLock.refusal && error?.code == .runnerFailed && error?.next?.contains("unlock") == true)
        #expect(capture.captured.isEmpty && !worktree.runner.calls.contains { $0.argv[0] == "ps" })
    }

    @Test func aLockedScreenRefusesARecordingStart() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses()
        var (service, ctx) = try setup(FakeWindowCapture(window: Self.window), granted: false, locked: true, running: [], detached: detached)
        let error = await #expect(throws: XcdError.self) { try await service.startRecording(device: "mac", out: nil, in: &ctx) }
        #expect(error == MacScreenLock.refusal && detached.starts.isEmpty)
        #expect(Recordings.load(ctx.paths.recordingFile(device: "mac")) == nil)
    }

    /// After a link, `AXMainWindow` can be an empty twin; the capture looks for the window with the content.
    @Test func theCaptureLooksForTheWindowWithContentNotAnEmptyTwin() async throws {
        defer { worktree.remove() }
        let chrome = FakeNode(role: "AXButton", subrole: "AXCloseButton", frame: ScreenRect(x: 2566, y: 255, w: 14, h: 16), actions: ["AXPress"])
        let windows = [MacSnapshotTests.window([chrome], title: "Twin"), MacSnapshotTests.window([MacSnapshotTests.button], title: "Probe")]
        let capture = FakeWindowCapture(window: Self.window)
        var (service, ctx) = try setup(capture, api: FakeAccessibility(app: FakeApp(windows: windows, hidden: true)))
        let report = try await service.screenshot(device: "mac", out: worktree.root + "/shot.png", in: &ctx)
        #expect(report.path == worktree.root + "/shot.png" && capture.captured == [report.path])
    }

    /// By the main window's title; of several, the largest at layer 0; of equals, the first.
    @Test func thePickTakesTheMainTitleThenTheLargestAtLayerZeroThenTheFirst() {
        func candidate(_ id: UInt32, _ title: String, width: Double, layer: Int = 0) -> WindowCandidate {
            WindowCandidate(window: CapturedWindow(id: id, title: title, frame: ScreenRect(x: 0, y: 0, w: width, h: 500)), layer: layer)
        }
        let hideTime = candidate(1, "", width: 500)                       // AppKit's untitled window of a hidden app
        #expect(WindowCandidate.pick([hideTime, candidate(2, "Probe", width: 900)], title: "Probe")?.id == 2)
        let several = [candidate(3, "Probe", width: 1200, layer: 3), candidate(4, "Probe", width: 900), candidate(5, "Probe", width: 1000)]
        #expect(WindowCandidate.pick(several, title: "Probe")?.id == 5)
        #expect(WindowCandidate.pick([candidate(6, "Probe", width: 900), candidate(7, "Probe", width: 900)], title: "Probe")?.id == 6)
        #expect(WindowCandidate.pick([candidate(8, "Probe", width: 900, layer: 3)], title: "Probe")?.id == 8)
        #expect(WindowCandidate.pick([hideTime, candidate(9, "", width: 900)], title: "")?.id == 9)
        #expect(WindowCandidate.pick([hideTime, candidate(10, "Twin", width: 900)], title: "Probe") == nil)
    }

    @Test func aRecordingStartsTheWindowRecorderAndStopsItByItsOwnMarker() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: { _, log in try "Recording started\n".write(toFile: log, atomically: true, encoding: .utf8) })
        var (service, ctx) = try setup(FakeWindowCapture(window: Self.window), detached: detached)
        let started = try await service.startRecording(device: "mac", out: worktree.root + "/clip.mp4", in: &ctx)
        let start = try #require(detached.starts.first)
        #expect(start.invocation.executable == "/usr/local/bin/xcd" && start.log == ctx.paths.logs + "/ui-record-mac.log")
        #expect(start.invocation.arguments == ["_record-window", "--window", "15610", "--out", worktree.root + "/clip.mp4", "--scale", "2.0"])
        #expect(started.action == .started && started.udid == nil && started.path == worktree.root + "/clip.mp4")
        let record = try #require(Recordings.load(ctx.paths.recordingFile(device: "mac")))
        #expect(record.recorder == MacWindowRecorder.marker && record.marker == MacWindowRecorder.marker)
        let stopped = try await service.stopRecording(device: "mac", in: ctx)
        #expect(stopped.action == .stopped && detached.stops.map(\.signal) == [SIGINT])
    }

    /// A recording runs while its own recorder does, so a second start is refused, not a restart.
    @Test func aMacRecordingStillRunningIsRefusedNotStartedAgain() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses()
        var (service, ctx) = try setup(FakeWindowCapture(window: Self.window), detached: detached)
        let file = ctx.paths.recordingFile(device: "mac")
        let recorder = ProcessIdentity(pid: 4242, startTime: 1, arguments: ["/usr/local/bin/xcd", MacWindowRecorder.marker, "--window", "15610"])
        try Recordings.save(RecordingRecord(device: "mac", udid: "mac", path: worktree.root + "/old.mp4", log: "/l", process: recorder,
                                            startedAt: Date(), recorder: MacWindowRecorder.marker), to: file)
        detached.adopt(recorder)
        let error = await #expect(throws: XcdError.self) { try await service.startRecording(device: "mac", out: nil, in: &ctx) }
        #expect(error?.code == .usage && error?.message == "mac is already recording to \(worktree.root)/old.mp4")
        #expect(detached.starts.isEmpty && Recordings.load(file)?.process == recorder)
        #expect(RecordingRecord(device: "d", udid: "U", path: "/p", log: "/l", process: recorder, startedAt: Date()).marker == Recordings.marker)
    }
}
