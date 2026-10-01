import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct AppHostTests {
    let fake = FakeProcessRunner()
    var simctl: SimctlClient { SimctlClient(runner: fake, developerDir: "/X.app/Contents/Developer", sleep: { _ in }) }
    let product = AppProduct(path: "/w/My App/.xcdev/DerivedData/Build/Products/Debug-iphonesimulator/SampleApp.app",
                             bundleId: "dev.xcdev.SampleApp", executableName: "SampleApp", platform: "iphonesimulator")
    let macProduct = AppProduct(path: "/w/DD/Build/Products/Debug/Mac App.app", bundleId: "dev.x.Mac",
                                executableName: "Mac App", platform: "macosx")

    @Test func simulatorLaunchCapturesOutputAndPassesEnvironment() async throws {
        fake.stub(["xcrun", "simctl", "launch"], stdout: "dev.xcdev.SampleApp: 46156\n")
        let pid = try await SimulatorAppHost(simctl: simctl, udid: "U1")
            .launch(product, arguments: ["-resetOnboarding", "YES"], environment: ["GREETING": "hi"], logFile: "/w/My App/app.log")
        #expect(pid == 46156)
        let call = try #require(fake.calls.first)
        #expect(call.arguments == ["simctl", "launch", "--terminate-running-process", "--stdout=/w/My App/app.log",
                                   "--stderr=/w/My App/app.log", "U1", "dev.xcdev.SampleApp", "-resetOnboarding", "YES"])
        #expect(call.environment == ["DEVELOPER_DIR": "/X.app/Contents/Developer", "SIMCTL_CHILD_GREETING": "hi",
                                     "SIMCTL_CHILD_NSUnbufferedIO": "YES", "SIMCTL_CHILD_OS_ACTIVITY_DT_MODE": "YES"])
    }

    @Test func simulatorLaunchOfAMissingAppExplainsWhatToDo() async throws {
        fake.stub(["xcrun", "simctl", "launch"], exitCode: 4,
                  stderr: "An error was encountered processing the command (domain=FBSOpenApplicationServiceErrorDomain, code=4):\nSimulator device failed to launch dev.xcdev.SampleApp.")
        let error = await #expect(throws: XcdError.self) {
            try await SimulatorAppHost(simctl: simctl, udid: "U1").launch(product, arguments: [], environment: [:], logFile: "/l")
        }
        #expect(error?.code == .simulatorFailed)
        #expect(error?.next == "install the app with `xcd install` (or use `xcd run`), then retry")
    }

    @Test func simulatorTerminateReportsWhetherAnythingRan() async throws {
        let host = SimulatorAppHost(simctl: simctl, udid: "U1")
        fake.stub(["xcrun", "simctl", "terminate"])
        #expect(try await host.terminate(product))
        fake.stub(["xcrun", "simctl", "terminate"], exitCode: 3,
                  stderr: "Simulator device failed to terminate dev.xcdev.SampleApp.\nfound nothing to terminate")
        #expect(try await host.terminate(product) == false)
        fake.stub(["xcrun", "simctl", "terminate"], exitCode: 149, stderr: "Unable to lookup in current state: Shutdown")
        #expect(try await host.terminate(product) == false)
        fake.stub(["xcrun", "simctl", "terminate"], exitCode: 148, stderr: "Invalid device: U1")
        await #expect(throws: XcdError.self) { try await host.terminate(product) }
    }

    @Test func simulatorInstallAndUninstall() async throws {
        fake.stub(["xcrun", "simctl", "install"])
        fake.stub(["xcrun", "simctl", "uninstall"])
        let host = SimulatorAppHost(simctl: simctl, udid: "U1")
        try await host.install(product)
        try await host.uninstall(product)
        #expect(fake.calls.map(\.arguments) == [["simctl", "install", "U1", product.path],
                                                ["simctl", "uninstall", "U1", "dev.xcdev.SampleApp"]])
    }

    @Test func macLaunchFindsTheNewProcessOfThisBuild() async throws {
        let exe = macProduct.executablePath
        let polls = Counter()
        fake.stub(["ps"]) { _ in
            let n = polls.increment()
            var out = "  100 \(exe)\n  200 /Applications/Other.app/Contents/MacOS/Other\n"
            if n >= 3 { out += "  300 \(exe)\n" }
            return ProcessOutput(stdout: out)
        }
        fake.stub(["open"])
        let pid = try await MacAppHost(runner: fake, sleep: { _ in })
            .launch(macProduct, arguments: ["-flag"], environment: ["GREETING": "hi"], logFile: "/w/app.log")
        #expect(pid == 300)
        let open = try #require(fake.calls.first { $0.argv[0] == "open" })
        #expect(open.arguments == ["-n", "-g", "--stdout", "/w/app.log", "--stderr", "/w/app.log",
                                   "--env", "GREETING=hi", "--env", "NSUnbufferedIO=YES", "--env", "OS_ACTIVITY_DT_MODE=YES",
                                   macProduct.path, "--args", "-flag"])
    }

    @Test func macLaunchThatNeverStartsFails() async throws {
        fake.stub(["ps"], stdout: "  100 /other\n")
        fake.stub(["open"])
        let error = await #expect(throws: XcdError.self) {
            try await MacAppHost(runner: fake, sleep: { _ in }).launch(macProduct, arguments: [], environment: [:], logFile: "/w/app.log")
        }
        #expect(error?.message == "Mac App did not start within 5s")
        #expect(error?.next == "read the app log: /w/app.log")
    }

    @Test func macTerminateStopsEveryCopyOfThisBuild() async throws {
        let exe = macProduct.executablePath
        fake.stub(["ps"], stdout: "  100 \(exe)\n  300 \(exe)\n  400 /other\n")
        fake.stub(["kill"])
        #expect(try await MacAppHost(runner: fake, sleep: { _ in }).terminate(macProduct))
        #expect(fake.calls.filter { $0.argv[0] == "kill" }.map(\.arguments) == [["-TERM", "100"], ["-TERM", "300"]])
        fake.stub(["ps"], stdout: "  400 /other\n")
        #expect(try await MacAppHost(runner: fake, sleep: { _ in }).terminate(macProduct) == false)
    }
}
