import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct RecordingsCheckTests {
    let fake = FakeProcessRunner()

    func recording(_ device: String, pid: Int32, startedAt: Date, in ctx: WorktreeContext) throws -> ProcessIdentity {
        let id = ProcessIdentity(pid: pid, startTime: 1, arguments: ["simctl", "io", "recordVideo"])
        try Recordings.save(RecordingRecord(device: device, udid: "U", path: ctx.paths.root + "/\(device).mp4", log: "/l",
                                            process: id, startedAt: startedAt), to: ctx.paths.recordingFile(device: device))
        return id
    }

    @Test func recordingsLeftBehindOrOverdueAreFixedOthersAreBusy() async throws {
        let (project, ctx) = try await fake.doctorProject()
        defer { project.remove() }
        let detached = FakeDetachedProcesses()
        let now = Date()
        _ = try recording("ended", pid: 1, startedAt: now, in: ctx)                                   // process gone
        detached.adopt(try recording("overdue", pid: 2, startedAt: now.addingTimeInterval(-3600), in: ctx))
        detached.adopt(try recording("fresh", pid: 3, startedAt: now, in: ctx))
        let service = DoctorService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                                    discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []), detached: detached)

        let report = await service.run(fix: false, from: nil)
        let check = try #require(report.checks.first { $0.id == "recordings" })
        #expect(check.problems.map(\.action) == [.forgetRecording, .stopRecording])
        #expect(check.problems.allSatisfy { $0.projectRoot == ctx.location.projectRoot })
        #expect(check.problems[1].message.contains("has been recording overdue for 1h00m"))
        #expect(check.inProgress.count == 1 && check.inProgress[0].contains("is recording fresh to "))
        #expect(detached.stops.isEmpty)

        let fixed = await service.run(fix: true, from: project.root)
        #expect(fixed.checks.first { $0.id == "recordings" }?.problems.allSatisfy(\.fixed) == true)
        #expect(detached.stops == [.init(pid: 2, signal: SIGINT)])
        #expect(ctx.paths.recordingFiles == [ctx.paths.recordingFile(device: "fresh")])
    }

    @Test func aRecordingReplacedAfterDetectionIsNotStopped() async throws {
        let (project, ctx) = try await fake.doctorProject()
        defer { project.remove() }
        let detached = FakeDetachedProcesses()
        let now = Date()
        detached.adopt(try recording("ui", pid: 2, startedAt: now.addingTimeInterval(-3600), in: ctx))
        let service = DoctorService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                                    discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []), detached: detached)
        let env = await service.environment(from: nil, fixing: true)
        let problem = try #require(await RecordingsCheck().detect(env).first)
        #expect(problem.action == .stopRecording)

        // Another xcd stops it and starts a fresh recording of the same device.
        detached.adopt(try recording("ui", pid: 7, startedAt: now, in: ctx))
        do {
            try await RecordingsCheck().fix(problem, env)
            Issue.record("expected DoctorLeftAlone")
        } catch is DoctorLeftAlone {}
        #expect(detached.stops.isEmpty)
        #expect(ctx.paths.recordingFiles == [ctx.paths.recordingFile(device: "ui")])
    }

    /// A Mac window recorder is `xcd _record-window`, not simctl, and it runs while that process does.
    @Test func aMacWindowRecorderIsSeenRunningByItsOwnMarker() async throws {
        let (project, ctx) = try await fake.doctorProject()
        defer { project.remove() }
        let detached = FakeDetachedProcesses()
        let recorder = ProcessIdentity(pid: 4, startTime: 1, arguments: ["/usr/local/bin/xcd", MacWindowRecorder.marker, "--window", "15610"])
        try Recordings.save(RecordingRecord(device: "mac", udid: "mac", path: ctx.paths.root + "/mac.mp4", log: "/l", process: recorder,
                                            startedAt: Date(), recorder: MacWindowRecorder.marker), to: ctx.paths.recordingFile(device: "mac"))
        detached.adopt(recorder)
        let service = DoctorService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                                    discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []), detached: detached)
        let check = try #require(await service.run(fix: false, from: nil).checks.first { $0.id == "recordings" })
        #expect(check.problems.isEmpty && check.inProgress.count == 1 && check.inProgress[0].contains("is recording mac to "))
    }
}
