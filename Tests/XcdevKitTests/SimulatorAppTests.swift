import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The check the real-simulator tests rest on when they say that nothing started the simulator's Mac app.
@Suite struct SimulatorAppTests {
    /// A Mac on which only the processes named in `running` exist.
    func mac(running: Set<String>) -> FakeProcessRunner {
        let runner = FakeProcessRunner()
        runner.stub(["pgrep", "-x"]) { invocation in
            ProcessOutput(exitCode: running.contains(invocation.arguments[1]) ? 0 : 1, stdout: "", stderr: "")
        }
        return runner
    }

    /// Xcode 27 has no Simulator.app: Device Hub shows its simulators, and its process is `DeviceHub`.
    @Test func eitherAppRunningCounts() async throws {
        #expect(try await SimulatorApp.isRunning(mac(running: ["Simulator", "Finder"])))
        #expect(try await SimulatorApp.isRunning(mac(running: ["DeviceHub", "Finder"])))
        #expect(try await !SimulatorApp.isRunning(mac(running: ["Finder", "Xcode", "SimulatorTrampoline"])))
    }

    /// The names as `lsappinfo info -only name` printed them on macOS 27: Device Hub's has a space, its process's none.
    @Test func eitherAppIsKnownByItsName() {
        #expect(SimulatorApp.isNamed(#""Simulator" ASN:0x0-0x1f01f: (in front) "#))
        #expect(SimulatorApp.isNamed(#""Device Hub" ASN:0x0-0xb55954e: (in front) "#))
        #expect(!SimulatorApp.isNamed(#""iTerm2" ASN:0x0-0x92092: (in front) "#))
    }
}
