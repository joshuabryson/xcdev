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

    @Test func poseLinesComeFromTheSimulatorsOwnLogAtDebugLevel() async throws {
        fake.stub(["xcrun", "simctl", "spawn"], stdout: Fixture.string("springboard-devicepose.log"))
        let lines = try await reader().poseLines(udid: udid, last: "boot")
        #expect(lines.map(\.degrees) == [90, 90, 0, 180])
        let call = try #require(fake.calls.last)
        #expect(call.arguments == ["simctl", "spawn", udid, "log", "show", "--last", "boot", "--debug", "--style", "compact",
                                   "--predicate", PostureReader.predicate])
        #expect(PostureReader.predicate == "process == \"SpringBoard\" AND category == \"DevicePose\" AND eventMessage BEGINSWITH \"DCMPose\"")
    }

    @Test func theStateIsTheDisplaysRefinedByTheLastLineOfThisBoot() async throws {
        fake.stub(["xcrun", "devicectl", "device", "info", "displays"], stdout: Fixture.string("devicectl-displays-open.json"))
        fake.stub(["xcrun", "simctl", "spawn"], stdout: Fixture.string("springboard-devicepose.log"))
        let state = try await reader().state(udid: udid)
        #expect(state == PostureState(innerActive: true, degrees: 180, posture: .open, orientation: .portrait))
        #expect(fake.commandLines.last?.contains("--last boot") == true)
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
