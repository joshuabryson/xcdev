import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct CrashTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-crash-\(UUID().uuidString)").path
    let launchedAt = Date()

    /// The simulator the recorded report came from.
    static let recordedSimulator = "C268DCFB-3E56-4C43-8947-B25ED3833F7E"

    /// Writes the recorded report; with `simulator`, as a crash of that simulator's process instead.
    func writeReport(named name: String = "SampleApp-2026-09-30-195619.ips", modified: Date? = nil,
                     simulator: String? = nil) throws -> String {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/" + name
        let recorded = Fixture.string("crash-sim.ips")
        let text = simulator.map { recorded.replacingOccurrences(of: Self.recordedSimulator, with: $0) } ?? recorded
        try text.write(toFile: path, atomically: true, encoding: .utf8)
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

    @Test func aReportBelongsToTheSimulatorItsProcessRanOn() {
        let text = Fixture.string("crash-sim.ips")
        #expect(CrashReport.ranIn(simulator: Self.recordedSimulator, reportText: text))
        #expect(!CrashReport.ranIn(simulator: "11111111-2222-3333-4444-555555555555", reportText: text))
        #expect(!CrashReport.ranIn(simulator: String(Self.recordedSimulator.dropLast()), reportText: text))
    }

    /// The report says where the process ran, or it counts for no simulator: a Mac app's, a damaged one, one with no path.
    @Test func aReportWhoseProcessPathCannotBeReadBelongsToNoSimulator() {
        let text = Fixture.string("crash-sim.ips")
        let simulator = Self.recordedSimulator
        let noPath = text.replacingOccurrences(of: "\"procPath\"", with: "\"procPathUnknown\"")
        let onTheMac = text.replacingOccurrences(of: "CoreSimulator/Devices/\(simulator)", with: "Xcode/DerivedData")
        let headerOnly = String(text.prefix { $0 != "\n" })
        for unreadable in [noPath, onTheMac, headerOnly, "{}\nnot json", "not an ips report", ""] {
            #expect(!CrashReport.ranIn(simulator: simulator, reportText: unreadable))
        }
    }

    /// Every simulator's crashes land in one folder. A simulator's own report is found even when another's is newer.
    @Test func aSimulatorsReportIsFoundWhicheverReportIsNewer() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let mine = "11111111-2222-3333-4444-555555555555"
        let own = try writeReport(named: "SampleApp-2026-09-30-195619.ips", simulator: mine)
        let newer = try writeReport(named: "SampleApp-2026-09-30-195700.ips")
        let locator = CrashReportLocator(directory: dir)
        #expect(locator.find(processName: "SampleApp", since: launchedAt)?.path == newer)
        #expect(locator.find(processName: "SampleApp", since: launchedAt, simulator: mine)?.path == own)
        #expect(locator.find(processName: "SampleApp", since: launchedAt, simulator: "99999999-2222-3333-4444-555555555555") == nil)
    }

    @Test func realProbeSeesThisProcess() {
        #expect(SystemProcessProbe().isRunning(getpid()))
        #expect(!SystemProcessProbe().isRunning(99_999_999))
    }
}
