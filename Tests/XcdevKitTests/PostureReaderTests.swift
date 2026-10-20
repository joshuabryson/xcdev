import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The two reads behind the witness.
@Suite struct PostureReaderTests {
    let fake = FakeProcessRunner()
    let udid = "ED703DE2-5FE6-4DE5-BB37-BA2FDA1DD7AB"

    func reader() -> PostureReader {
        PostureReader(runner: fake, developerDir: "/X.app/Contents/Developer", now: { Date() }, sleep: { _ in await Task.yield() })
    }

    @Test func displaysAskDevicectlForJSONOnStdout() async throws {
        fake.stub(["xcrun", "devicectl", "device", "info", "displays"], stdout: Fixture.string("devicectl-displays-open.json"))
        let read = try await reader().displays(udid: udid)
        #expect(read.innerActive && read.poseOrientation == .portrait)
        let call = try #require(fake.calls.last)
        #expect(call.arguments == ["devicectl", "device", "info", "displays", "--device", udid, "--json-output", "-"])
        #expect(call.environment["DEVELOPER_DIR"] == "/X.app/Contents/Developer")
    }

    /// The hinge lines and the orientation updates both come from one read of the simulator's own log at debug level.
    @Test func theWitnessLogComesFromTheSimulatorsOwnLogAtDebugLevel() async throws {
        fake.stub(["xcrun", "simctl", "spawn"],
                  stdout: Fixture.string("springboard-devicepose.log") + Fixture.string("springboard-orientation.log"))
        let log = try await reader().witnessLog(udid: udid, last: "boot")
        #expect(log.poses.map(\.degrees) == [90, 90, 0, 180, 180, 90])
        #expect(log.orientations.map(\.word) == ["landscapeLeft", "landscapeRight"])
        let call = try #require(fake.calls.last)
        #expect(call.arguments == ["simctl", "spawn", udid, "log", "show", "--last", "boot", "--debug", "--style", "compact",
                                   "--predicate", PostureReader.predicate])
        #expect(PostureReader.predicate == "process == \"SpringBoard\" AND ((category == \"DevicePose\" AND eventMessage BEGINSWITH \"DCMPose\") OR (category == \"DisplayContentMode\" AND eventMessage BEGINSWITH \"COMPLETED\") OR (category == \"DeviceOrientationUpdateDeferral\" AND eventMessage BEGINSWITH \"Updated device orientation update\"))")
    }

    /// The fixture ends with a half merged into a running open: the open's `DCMPose` line says 180°, and only the
    /// transition's `COMPLETED:` line says where the hinge went. It has no orientation update, so the
    /// orientation is devicectl's mapped word.
    @Test func theStateIsTheDisplaysRefinedByTheLastLineOfThisBoot() async throws {
        fake.stub(["xcrun", "devicectl", "device", "info", "displays"], stdout: Fixture.string("devicectl-displays-open.json"))
        fake.stub(["xcrun", "simctl", "spawn"], stdout: Fixture.string("springboard-devicepose.log"))
        let state = try await reader().state(udid: udid)
        #expect(state == PostureState(innerActive: true, degrees: 90, posture: .half, orientation: .portrait))
        #expect(fake.commandLines.last?.contains("--last boot") == true)
    }

    /// devicectl's word is the screen's (here `landscapeRight`, portrait once turned a quarter); the last orientation
    /// update of the boot is the device's, and wins.
    @Test func theStateTakesTheOrientationFromTheLastUpdateNotTheScreen() async throws {
        fake.stub(["xcrun", "devicectl", "device", "info", "displays"], stdout: Fixture.string("devicectl-displays-open.json"))
        fake.stub(["xcrun", "simctl", "spawn"],
                  stdout: Fixture.string("springboard-devicepose.log") + Fixture.string("springboard-orientation.log"))
        let state = try await reader().state(udid: udid)
        #expect(state == PostureState(innerActive: true, degrees: 90, posture: .half, orientation: .landscapeRight))
    }

    @Test func withoutALineThePostureIsOnlyWhatTheDisplaySays() async throws {
        fake.stub(["xcrun", "devicectl", "device", "info", "displays"], stdout: Fixture.string("devicectl-displays-open.json"))
        fake.stub(["xcrun", "simctl", "spawn"], stdout: "Filtering the log data using \"…\"\n")
        let state = try await reader().state(udid: udid)
        #expect(state.posture == nil && state.degrees == nil && state.postureText == "open or half")
    }

    @Test func aFailingToolIsSimulatorFailedWithDoctorNext() async throws {
        fake.stub(["xcrun", "devicectl"], exitCode: 1, stderr: "ERROR: The specified device was not found.")
        let error = await #expect(throws: XcdError.self) { try await reader().displays(udid: udid) }
        #expect(error?.code == .simulatorFailed && error?.next == "run `xcd doctor`")
    }
}
