import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct CrashTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-crash-\(UUID().uuidString)").path
    let launchedAt = Date()

    func writeReport(named name: String = "SampleApp-2026-09-30-195619.ips", modified: Date? = nil) throws -> String {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/" + name
        try Fixture.string("crash-sim.ips").write(toFile: path, atomically: true, encoding: .utf8)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path) }
        return path
    }

    func watcher(_ probe: FakeProbe) -> CrashWatcher {
        CrashWatcher(probe: probe, locator: CrashReportLocator(directory: dir), sleep: { _ in })
    }

    @Test func parsesARecordedSimulatorCrash() throws {
        let report = try CrashReport.parse(Fixture.string("crash-sim.ips"), path: "/r/SampleApp.ips")
        #expect(report.processName == "SampleApp" && report.pid == 46606)
        #expect(report.bundleId == "dev.xcdev.SampleApp")
        #expect(report.exception == "EXC_BREAKPOINT (SIGTRAP)")
        #expect(report.termination == "Trace/BPT trap: 5")
        #expect(report.frames == [
            "libswiftCore.dylib  _assertionFailure(_:_:file:line:flags:)",
            "SampleApp.debug.dylib  closure #1 in SampleAppApp.init() (SampleAppApp.swift:14)",
            "SampleApp.debug.dylib  thunk for @escaping @callee_guaranteed @Sendable () -> ()",
            "libdispatch.dylib  _dispatch_client_callout",
            "libdispatch.dylib  _dispatch_continuation_pop",
        ])
    }

    @Test func notAnIPSFileThrows() {
        #expect(throws: XcdError.self) { try CrashReport.parse("just text", path: "/x.ips") }
    }

    @Test func aProcessThatKeepsRunningIsRunning() async throws {
        #expect(try await watcher(FakeProbe()).watch(pid: 1, processName: "SampleApp", window: .seconds(5),
                                                     launchedAt: launchedAt) == .running)
    }

    @Test func aCrashIsMatchedToItsReportByPid() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try writeReport()
        let outcome = try await watcher(FakeProbe(runningChecks: 2))
            .watch(pid: 46606, processName: "SampleApp", window: .seconds(5), launchedAt: launchedAt)
        guard case .exited(let after, let crash) = outcome else { Issue.record("expected an exit"); return }
        #expect(after == 0.5)
        #expect(crash?.path == path && crash?.pid == 46606)
    }

    @Test func anotherProcessesReportIsNotBlamed() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = try writeReport()
        #expect(try await watcher(FakeProbe(runningChecks: 0))
            .watch(pid: 999, processName: "SampleApp", window: .seconds(5), launchedAt: launchedAt)
            == .exited(after: 0, crash: nil))
    }

    @Test func aReportFromBeforeTheLaunchIsIgnored() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = try writeReport(modified: launchedAt.addingTimeInterval(-3600))
        #expect(CrashReportLocator(directory: dir).find(processName: "SampleApp", pid: 46606, since: launchedAt) == nil)
    }

    @Test func aProcessNeverSeenRunningIsMatchedByNameAndTime() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try writeReport()
        #expect(CrashReportLocator(directory: dir).find(processName: "SampleApp", since: launchedAt)?.path == path)
        #expect(CrashReportLocator(directory: dir).find(processName: "Other", since: launchedAt) == nil)
        _ = try writeReport(modified: launchedAt.addingTimeInterval(-3600))
        #expect(CrashReportLocator(directory: dir).find(processName: "SampleApp", since: launchedAt.addingTimeInterval(60)) == nil)
    }

    @Test func realProbeSeesThisProcess() {
        #expect(SystemProcessProbe().isRunning(getpid()))
        #expect(!SystemProcessProbe().isRunning(99_999_999))
    }
}
