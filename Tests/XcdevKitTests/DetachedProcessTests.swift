import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct DetachedProcessTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd detached \(UUID().uuidString)").path
    let launcher = SystemDetachedProcesses(inheritedEnvironment: ["PATH": "/usr/bin:/bin"])

    /// Whether `condition` holds within 10 s, checked every 10 ms: a started process gets there in its own time.
    func soon(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func log(_ path: String, says text: String) -> Bool {
        (try? String(contentsOfFile: path, encoding: .utf8))?.contains(text) == true
    }

    @Test(.timeLimit(.minutes(1))) func aStartedProcessHasItsOwnSessionAndOutlivesItsStarter() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = dir + "/logs/a.log"
        let id = try launcher.start(Invocation("/bin/sh", ["-c", "echo started; exec sleep 30"]), log: log)
        #expect(getsid(id.pid) == id.pid)                       // its own session: no terminal signal reaches it
        #expect(getpgid(id.pid) == id.pid)
        #expect(launcher.inspector.isRunning(id))
        #expect(try await soon { self.log(log, says: "started") })
        #expect(try await soon { launcher.inspector.identity(of: id.pid)?.arguments == ["sleep", "30"] })   // read back after exec
        #expect(await launcher.stop(id, marker: "sleep", signal: SIGINT, timeout: .seconds(5)) == .stopped)
        #expect(!launcher.inspector.isRunning(id))
        #expect(await launcher.stop(id, marker: nil, signal: SIGINT, timeout: .seconds(5)) == .notRunning)
    }

    @Test(.timeLimit(.minutes(1))) func aProcessThatIgnoresTheSignalIsKilled() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = dir + "/b.log"
        let id = try launcher.start(Invocation("/bin/sh", ["-c", "trap '' INT; echo ignoring; while :; do sleep 1; done"]), log: log)
        #expect(try await soon { self.log(log, says: "ignoring") })
        #expect(await launcher.stop(id, marker: nil, signal: SIGINT, timeout: .milliseconds(100)) == .killed)
        #expect(!launcher.inspector.isRunning(id))
    }

    @Test func stopNeverSignalsAProcessThatOnlySharesThePid() async throws {
        let me = try #require(SystemProcessInspector().identity(of: getpid()))
        let impostor = ProcessIdentity(pid: me.pid, startTime: me.startTime - 1, arguments: me.arguments)
        #expect(!launcher.inspector.isRunning(impostor))
        #expect(await launcher.stop(impostor, marker: nil, signal: SIGKILL, timeout: .seconds(1)) == .notRunning)
        #expect(!launcher.inspector.isRunning(me, marker: "recordVideo"))   // same process, wrong program
    }

    /// A process that exits at once is either reported by `start` or, if `start` won the race, gone right after.
    @Test func aProcessThatExitsAtOnceIsNeverReportedRunning() async throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            let id = try launcher.start(Invocation("/bin/sh", ["-c", "exit 3"]), log: dir + "/c.log")
            #expect(try await soon { !launcher.inspector.isRunning(id) })
        } catch let error as XcdError {
            #expect(error.code == .subprocessFailed)
        }
    }

    /// `kill(-1, …)` signals every process the user owns, and group 0 is xcd's own: neither may ever be sent.
    @Test func signalGroupRefusesPidsThatAreNotAProcessGroupLeader() {
        let inspector = SystemProcessInspector()
        #expect(!inspector.signalGroup(1, 0))
        #expect(!inspector.signalGroup(0, 0))
        #expect(!inspector.signalGroup(-1, 0))
    }

    @Test func aMissingExecutableIsSubprocessFailed() {
        let error = #expect(throws: XcdError.self) { _ = try launcher.start(Invocation("/no/such/tool", []), log: dir + "/d.log") }
        #expect(error?.code == .subprocessFailed)
    }
}
