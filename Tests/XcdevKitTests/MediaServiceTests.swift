import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct MediaServiceTests {
    let worktree = FakeWorktree(prefix: "xcd media")
    static let yaml = """
    version: 1
    project: App.xcodeproj
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro" }
    ui: { media: { dir: "shots/{device}" }, record: { maxDuration: 1m } }
    """

    /// A booted fake clone, and a launcher whose recordings print "Recording started" at once.
    func setup(detached: FakeDetachedProcesses = FakeDetachedProcesses(onStart: { _, log in
        try "Recording started\n".write(toFile: log, atomically: true, encoding: .utf8)
    }), now: Date = Date(timeIntervalSince1970: 1_791_085_501)) throws -> (MediaService, WorktreeContext, FakeSimulators) {
        let sims = try FakeSimulators(runner: worktree.runner, catalogJSON: Fixture.string("simctl-list.json"))
        worktree.runner.stub(["xcrun", "simctl", "io"]) { inv in
            FileManager.default.createFile(atPath: inv.arguments.last!, contents: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0x04, 0xB6, 0, 0, 0x0A, 0x3E]))
            return ProcessOutput(stderr: "Wrote screenshot to: \(inv.arguments.last!)\n")
        }
        let service = MediaService(provisioner: worktree.provisioner, detached: detached, currentDirectory: worktree.root + "/cwd",
                                   now: { now }, sleep: { _ in }, startTimeout: .milliseconds(300))
        let ctx = try worktree.context(Self.yaml)
        // SystemDetachedProcesses creates the log's folder; the fake only runs `onStart`, which writes the log.
        try FileManager.default.createDirectory(atPath: ctx.paths.logs, withIntermediateDirectories: true)
        return (service, ctx, sims)
    }

    @Test func aScreenshotLandsInTheMediaFolderWithItsSize() async throws {
        defer { worktree.remove() }
        var (service, ctx, _) = try setup()
        let report = try await service.screenshot(device: nil, out: nil, in: &ctx)
        #expect(report.path.hasPrefix(worktree.root + "/shots/iphone/") && report.path.hasSuffix("-iphone-screenshot.png"))
        #expect(report.width == 1206 && report.height == 2622)
        #expect(report.text.hasPrefix("screenshot iphone  path=\(report.path)  1206x2622px"))
        #expect(try String(contentsOfFile: worktree.root + "/.gitignore", encoding: .utf8).contains("shots/\n"))
        #expect(report.gitignoreAdded == "shots/")
        #expect(report.text.contains("\nnote: added shots/ to .gitignore in \(worktree.root)"))
        let second = try await service.screenshot(device: nil, out: nil, in: &ctx)
        #expect(second.gitignoreAdded == nil && !second.text.contains("gitignore"))
    }

    @Test func aGitignoreThatCantBeWrittenIsAWarningNotAFailure() async throws {
        defer { worktree.remove() }
        var (service, ctx, _) = try setup()
        try FileManager.default.createDirectory(atPath: worktree.root + "/.gitignore", withIntermediateDirectories: true)
        let report = try await service.screenshot(device: nil, out: nil, in: &ctx)
        #expect(report.gitignoreAdded == nil && report.gitignoreWarning?.hasPrefix("could not add shots/ to .gitignore: ") == true)
        #expect(report.text.contains("\nwarning: could not add shots/ to .gitignore: "))
    }

    @Test func outIsRelativeToTheCurrentDirectoryAndNeverOverwrites() async throws {
        defer { worktree.remove() }
        var (service, ctx, _) = try setup()
        let report = try await service.screenshot(device: nil, out: "new/dir/a.png", in: &ctx)
        #expect(report.path == worktree.root + "/cwd/new/dir/a.png")
        let again = await #expect(throws: XcdError.self) { _ = try await service.screenshot(device: nil, out: "new/dir/a.png", in: &ctx) }
        #expect(again?.code == .usage && again?.next == "pick another --out, or delete it first")
        let video = await #expect(throws: XcdError.self) { _ = try await service.startRecording(device: nil, out: "new/dir/a.png", in: &ctx) }
        #expect(video?.code == .usage)
    }

    @Test func recordingStartsDetachedAndStopsWithSIGINT() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: { _, log in try "Recording started\n".write(toFile: log, atomically: true, encoding: .utf8) })
        var (service, ctx, _) = try setup(detached: detached)
        let started = try await service.startRecording(device: nil, out: nil, in: &ctx)
        let start = try #require(detached.starts.first)
        #expect(start.invocation.commandLine.hasPrefix("xcrun simctl io ") && start.invocation.arguments.contains("--codec=h264"))
        #expect(start.log == ctx.paths.logs + "/ui-record-iphone.log")
        #expect(started.action == .started && started.path?.hasSuffix("-iphone-recording.mp4") == true)
        #expect(Recordings.load(ctx.paths.recordingFile(device: "iphone"))?.process == start.identity)
        #expect(started.text.contains("next: stop it with `xcd ui record stop`"))
        #expect(started.gitignoreAdded == "shots/")
        #expect(started.text.contains("\nnote: added shots/ to .gitignore in \(worktree.root)\nnext: stop it"))

        let twice = await #expect(throws: XcdError.self) { _ = try await service.startRecording(device: nil, out: nil, in: &ctx) }
        #expect(twice?.code == .usage && twice?.message.contains("already recording") == true)

        let stopped = try await service.stopRecording(device: nil, in: ctx)
        #expect(detached.stops.map(\.pid) == [start.identity.pid] && detached.stops.map(\.signal) == [SIGINT])
        #expect(stopped.action == .stopped && stopped.outcome == .stopped)
        #expect(Recordings.load(ctx.paths.recordingFile(device: "iphone")) == nil)
        #expect(try await service.stopRecording(device: nil, in: ctx).action == .notRecording)
    }

    @Test func aRecordingThatWontStopIsKilledAndSaysSo() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: { _, log in try "Recording started\n".write(toFile: log, atomically: true, encoding: .utf8) },
                                             stopResult: .killed)
        var (service, ctx, _) = try setup(detached: detached)
        _ = try await service.startRecording(device: nil, out: nil, in: &ctx)
        let stopped = try await service.stopRecording(device: nil, in: ctx)
        #expect(stopped.outcome == .killed)
        #expect(stopped.text.contains("warning: simctl didn't finish within 45.0s and was killed, so the video may be incomplete"))
    }

    @Test func aRecordingThatNeverStartsIsStoppedAndReported() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: { _, log in try "Note: something else\n".write(toFile: log, atomically: true, encoding: .utf8) })
        var (service, ctx, _) = try setup(detached: detached)
        let error = await #expect(throws: XcdError.self) { _ = try await service.startRecording(device: nil, out: nil, in: &ctx) }
        #expect(error?.code == .simulatorFailed && error?.message == "the recording didn't start within 0.3s")
        #expect(detached.stops.map(\.signal) == [SIGINT])
        #expect(Recordings.load(ctx.paths.recordingFile(device: "iphone")) == nil)
    }

    @Test func aStartInterruptedWhileWaitingStopsTheRecorderAndLeavesNoRecord() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: { _, log in try "Note: nothing yet\n".write(toFile: log, atomically: true, encoding: .utf8) })
        var (_, ctx, _) = try setup(detached: detached)
        let service = MediaService(provisioner: worktree.provisioner, detached: detached, currentDirectory: worktree.root,
                                   now: { Date(timeIntervalSince1970: 1_791_085_501) }, sleep: { _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) { _ = try await service.startRecording(device: nil, out: nil, in: &ctx) }
        let start = try #require(detached.starts.first)
        #expect(detached.stops.map(\.pid) == [start.identity.pid] && detached.stops.map(\.signal) == [SIGINT])
        #expect(Recordings.load(ctx.paths.recordingFile(device: "iphone")) == nil)
    }

    @Test func aRecorderThatExitsBeforeStartingIsReported() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: { _, log in try "Note: nothing yet\n".write(toFile: log, atomically: true, encoding: .utf8) })
        var (_, ctx, _) = try setup(detached: detached)
        let service = MediaService(provisioner: worktree.provisioner, detached: detached, currentDirectory: worktree.root,
                                   now: { Date(timeIntervalSince1970: 1_791_085_501) },
                                   sleep: { _ in if let pid = detached.starts.first?.identity.pid { detached.exit(pid: pid) } })
        let error = await #expect(throws: XcdError.self) { _ = try await service.startRecording(device: nil, out: nil, in: &ctx) }
        #expect(error?.code == .simulatorFailed && error?.message == "simctl stopped before the recording started")
        #expect(Recordings.load(ctx.paths.recordingFile(device: "iphone")) == nil)
    }

    @Test func aRecordWhosePidWasReusedIsNeverSignalled() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: { _, log in try "Recording started\n".write(toFile: log, atomically: true, encoding: .utf8) })
        var (service, ctx, _) = try setup(detached: detached)
        let stale = RecordingRecord(device: "iphone", udid: "U", path: "/old.mp4", log: "/old.log",
                                    process: ProcessIdentity(pid: 777, startTime: 100, arguments: ["simctl", "recordVideo"]),
                                    startedAt: Date(timeIntervalSince1970: 0))
        try Recordings.save(stale, to: ctx.paths.recordingFile(device: "iphone"))
        detached.adopt(ProcessIdentity(pid: 777, startTime: 999, arguments: ["vim"]))      // pid 777 is someone else now
        #expect(try await service.stopRecording(device: nil, in: ctx).outcome == .notRunning)
        try Recordings.save(stale, to: ctx.paths.recordingFile(device: "iphone"))
        _ = try await service.startRecording(device: nil, out: nil, in: &ctx)               // the stale record doesn't block
        #expect(detached.stops.isEmpty)
    }

    @Test func overdueRecordingsAreStoppedOthersAreLeftRunning() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses(onStart: { _, log in try "Recording started\n".write(toFile: log, atomically: true, encoding: .utf8) })
        var (service, ctx, _) = try setup(detached: detached)
        _ = try await service.startRecording(device: nil, out: nil, in: &ctx)
        #expect(await service.stopOverdue(in: ctx).isEmpty)                                  // limit is 1m; just started
        let later = MediaService(provisioner: worktree.provisioner, detached: detached, currentDirectory: worktree.root,
                                 now: { Date(timeIntervalSince1970: 1_791_085_501 + 61) }, sleep: { _ in })
        let stops = await later.stopOverdue(in: ctx)
        #expect(stops.map(\.device) == ["iphone"] && stops.first?.seconds == 61)
        #expect(stops.first?.note.hasPrefix("stopped the iphone recording after 1m01s: ") == true)
        #expect(detached.stops.map(\.signal) == [SIGINT])
    }

    @Test func stopAllStopsOneDeviceOrEvery() async throws {
        defer { worktree.remove() }
        let detached = FakeDetachedProcesses()
        let ctx = try worktree.context(Self.yaml)
        for (index, device) in ["iphone", "ipad"].enumerated() {
            let id = ProcessIdentity(pid: Int32(900 + index), startTime: 1, arguments: ["simctl", "recordVideo"])
            detached.adopt(id)
            try Recordings.save(RecordingRecord(device: device, udid: "U\(index)", path: "/\(device).mp4", log: "/l",
                                                process: id, startedAt: Date()), to: ctx.paths.recordingFile(device: device))
        }
        #expect(await Recordings.stopAll(in: ctx.paths, device: "ipad", detached: detached, now: Date()).map(\.device) == ["ipad"])
        #expect(await Recordings.stopAll(in: ctx.paths, detached: detached, now: Date()).map(\.device) == ["iphone"])
        #expect(ctx.paths.recordingFiles.isEmpty)
    }
}
