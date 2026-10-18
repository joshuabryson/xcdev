import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// What `xcd doctor` says to try when CoreSimulator still doesn't answer (the rest of the check is in `DoctorTests`).
@Suite struct CoreSimulatorCheckTests {
    let fake = FakeProcessRunner()

    /// Xcode 27 has no Simulator.app; Device Hub is its app that holds simulators.
    @Test func theHintNamesTheSimulatorAppOfEitherXcode() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        fake.stub(["xcrun", "simctl", "list", "-j"], exitCode: 1, stderr: "Failed to initialize simulator device set.")
        let doctor = DoctorService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                                   discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []),
                                   sleep: { _ in await Task.yield() })
        let report = await doctor.run(fix: false, checks: [CoreSimulatorCheck()], from: nil)
        #expect(report.problems.first?.check == "coresimulator")
        #expect(report.problems.first?.next == "if it still fails, ask the user to quit Device Hub (Simulator.app before Xcode 27) and Xcode, or to restart the Mac: either shuts down every booted simulator on this Mac, other agents' too")
    }
}
