import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"

/// A clone's idle session on a real simulator. The watchdog is the built xcd, which `services(_:)` names, so run
/// `swift build` first.
@Suite(.enabled(if: enabled, "set XCD_INTEGRATION=1 to run (needs Xcode + an iOS simulator runtime, and swift build first)"),
       .serialized)
struct IdleShutdownIntegrationTests {
    let runner = SystemProcessRunner()

    func project() async throws -> TempProject {
        try TempProject.make(config: """
        version: 1
        project: SampleApp.xcodeproj
        defaultDevice: iphone
        devices:
          iphone: { type: "\(try await firstIPhoneType(runner).name)" }
        """, name: "Idle App \(UUID().uuidString.prefix(6))", fixture: repoRoot + "/Fixtures/SampleApp", parent: testsHome)
    }

    @Test(.timeLimit(.minutes(5))) func anIdleCloneShutsItselfDown() async throws {
        try await withCleanup(try await project()) { svc in
            var ctx = try await svc.open(worktree: nil, idle: 5)
            let udid = try #require(try await svc.provisioner.bootReport(nil, in: &ctx).udid)
            LeaseHolds.shared.release(udid)  // this test process is not a command that keeps running
            #expect(try await waitUntil(seconds: 60) { try await state(udid) == "Shutdown" }, "\(watchdogLog(ctx))")
            // The watchdog removes the lease after simctl's shutdown returns, then exits.
            #expect(try await waitUntil(seconds: 10) { try await watchdogProcesses(udid).isEmpty })
            #expect(DeviceLeases(globalPaths: svc.globalPaths).load(udid) == nil)
            #expect(watchdogLog(ctx).contains("shut down \(udid) after "), "\(watchdogLog(ctx))")
        }
    }

    @Test(.timeLimit(.minutes(5))) func shutdownAllEndsTheSession() async throws {
        try await withCleanup(try await project()) { svc in
            var ctx = try await svc.open(worktree: nil)
            let udid = try #require(try await svc.provisioner.bootReport(nil, in: &ctx).udid)
            #expect(try await watchdogProcesses(udid).count == 1, "\(watchdogLog(ctx))")
            let report = try await svc.provisioner.shutdownAllReport(in: ctx, detached: svc.detached)
            #expect(report.devices.first?.action == "shut down")
            #expect(try await state(udid) == "Shutdown")
            #expect(try await watchdogProcesses(udid).isEmpty)
            LeaseHolds.shared.release(udid)
        }
    }

    @Test(.timeLimit(.minutes(5))) func aHeldLeaseKeepsTheCloneBooted() async throws {
        try await withCleanup(try await project()) { svc in
            var ctx = try await svc.open(worktree: nil, idle: 5)
            let udid = try #require(try await svc.provisioner.bootReport(nil, in: &ctx).udid)
            try await Task.sleep(for: .seconds(15))  // the lease is held by this process the whole time
            #expect(try await state(udid) == "Booted", "\(watchdogLog(ctx))")
            LeaseHolds.shared.release(udid)
            #expect(try await waitUntil(seconds: 60) { try await state(udid) == "Shutdown" }, "\(watchdogLog(ctx))")
        }
    }

    /// The clone's state in `simctl list`; nil when it is not listed.
    func state(_ udid: String) async throws -> String? {
        try await SimctlClient(runner: runner, developerDir: nil).catalog().device(udid: udid)?.state
    }

    /// The running watchdogs of `udid`, as `pgrep -fl` lists them.
    func watchdogProcesses(_ udid: String) async throws -> [String] {
        let result = try await runner.run(Invocation("/usr/bin/pgrep", ["-fl", "\(Watchdogs.marker) \(udid)"]))
        try #require(result.exitCode <= 1, "pgrep failed: \(result.stderrString)")  // 1: nothing matched
        return result.stdoutString.split(separator: "\n").map(String.init)
    }

    /// Polls `condition` once a second until it holds or `seconds` have passed; whether it held.
    func waitUntil(seconds: Int, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .seconds(1))
        }
        return try await condition()
    }

    /// Every watchdog log of the worktree, for a failure message.
    func watchdogLog(_ ctx: WorktreeContext) -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: ctx.paths.logs)) ?? []
        return names.filter { $0.contains("watchdog") }.sorted()
            .compactMap { try? String(contentsOfFile: ctx.paths.logs + "/" + $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}
