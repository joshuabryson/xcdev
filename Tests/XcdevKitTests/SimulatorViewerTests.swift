import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// What Device Hub does with each URL here was checked against Xcode 27.0 (27A266a) on a simulator made for it.
@Suite struct SimulatorViewerTests {
    func viewer(_ version: String, path: String = "/Applications/Xcode.app") -> SimulatorViewer {
        SimulatorViewer(xcode: XcodeInstall(path: path, version: version, build: "x"))
    }

    @Test(arguments: ["27.0", "27", "27.1.2", "28.0"])
    func xcode27AndLaterShowSimulatorsInDeviceHub(version: String) {
        #expect(viewer(version) == .deviceHub("/Applications/Xcode.app/Contents/Applications/DeviceHub.app"))
    }

    @Test(arguments: ["26.5", "26.0.1", "16.4", "not a version"])
    func earlierXcodesHaveSimulatorApp(version: String) {
        #expect(viewer(version) == .simulatorApp)
    }

    /// Two Xcodes can be installed; the one this worktree builds with shows its own Device Hub.
    @Test func deviceHubIsTheOneInsideTheXcodeInUse() {
        #expect(viewer("27.1", path: "/Applications/Xcode beta.app")
                == .deviceHub("/Applications/Xcode beta.app/Contents/Applications/DeviceHub.app"))
    }

    @Test func deviceHubIsToldWhichSimulatorByAURL() async throws {
        let fake = FakeProcessRunner()
        fake.stub(["open"]) { _ in ProcessOutput() }
        try await SimctlClient(runner: fake, developerDir: nil)
            .show(udid: "ABCD-12", in: .deviceHub("/X.app/Contents/Applications/DeviceHub.app"))
        #expect(fake.calls.map(\.executable) == ["/usr/bin/open"])
        #expect(fake.calls.last?.arguments == ["-a", "/X.app/Contents/Applications/DeviceHub.app", "devices://manage/select?id=ABCD-12"])
    }

    @Test func simulatorAppIsToldByALaunchArgument() async throws {
        let fake = FakeProcessRunner()
        fake.stub(["open"]) { _ in ProcessOutput() }
        try await SimctlClient(runner: fake, developerDir: nil).show(udid: "ABCD-12", in: .simulatorApp)
        #expect(fake.calls.map(\.executable) == ["/usr/bin/open"])
        #expect(fake.calls.last?.arguments == ["-a", "Simulator", "--args", "-CurrentDeviceUDID", "ABCD-12"])
    }

    /// An Xcode whose Device Hub is missing: `open` exits 1 and says why, in these words.
    @Test func anAppThatCannotBeOpenedIsAnError() async throws {
        let said = "The application /X.app/Contents/Applications/DeviceHub.app cannot be opened for an unexpected reason"
        let fake = FakeProcessRunner()
        fake.stub(["open"], exitCode: 1, stderr: said)
        let error = await #expect(throws: XcdError.self) {
            try await SimctlClient(runner: fake, developerDir: nil)
                .show(udid: "ABCD-12", in: .deviceHub("/X.app/Contents/Applications/DeviceHub.app"))
        }
        #expect(error?.code == .subprocessFailed && error?.details.last == said)
    }

    @Test func onlyDeviceHubIsKnownToShutSimulatorsDownWhenItQuits() {
        #expect(SimulatorViewer.simulatorApp.notes.isEmpty)
        #expect(SimulatorViewer.deviceHub("/X.app/Contents/Applications/DeviceHub.app").notes
                == ["quitting Device Hub shuts down every booted simulator on this Mac, other worktrees' clones included"])
    }
}
