import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct SimctlDeviceStateTests {
    let fake = FakeProcessRunner()
    var client: SimctlClient { SimctlClient(runner: fake, developerDir: "/X.app/Contents/Developer", sleep: { _ in }) }

    @Test func passesTheExactArguments() async throws {
        fake.stub(["xcrun", "simctl"])
        fake.stub(["xcrun", "simctl", "pbpaste"], stdout: "hello pasteboard")
        try await client.openURL(udid: "U", url: "myapp://a b")
        try await client.push(udid: "U", bundleId: "b.id", payloadFile: "/p/push.json")
        try await client.privacy(udid: "U", action: .grant, service: "photos", bundleId: "b.id")
        try await client.privacy(udid: "U", action: .reset, service: "all", bundleId: nil)
        try await client.overrideStatusBar(udid: "U", StatusBarOverrides(time: "9:41", batteryLevel: 100, batteryState: "charged",
                                                                        wifiBars: 3, cellularBars: 4, network: "5g", operatorName: ""))
        try await client.clearStatusBar(udid: "U")
        try await client.setAppearance(udid: "U", .dark)
        try await client.setLocation(udid: "U", Coordinate(latitude: 37.33, longitude: -122.03))
        try await client.setLocation(udid: "U", nil)
        try await client.copyText(udid: "U", file: "/t/clip.txt")
        #expect(try await client.pasteText(udid: "U") == "hello pasteboard")
        try await client.addMedia(udid: "U", files: ["/a b.png", "/c.mov"])
        try await client.screenshot(udid: "U", path: "/m/s.png")
        #expect(fake.commandLines == [
            "xcrun simctl openurl U 'myapp://a b'",
            "xcrun simctl push U b.id /p/push.json",
            "xcrun simctl privacy U grant photos b.id",
            "xcrun simctl privacy U reset all",
            "xcrun simctl status_bar U override --time 9:41 --batteryLevel 100 --batteryState charged --wifiBars 3 --cellularBars 4 --dataNetwork 5g --operatorName ''",
            "xcrun simctl status_bar U clear",
            "xcrun simctl ui U appearance dark",
            "xcrun simctl location U set 37.33,-122.03",
            "xcrun simctl location U clear",
            "xcrun simctl pbcopy U",
            "xcrun simctl pbpaste U",
            "xcrun simctl addmedia U '/a b.png' /c.mov",
            "xcrun simctl io U screenshot /m/s.png",
        ])
        #expect(fake.calls[9].inputFile == "/t/clip.txt")
        #expect(fake.calls.allSatisfy { $0.environment["DEVELOPER_DIR"] == "/X.app/Contents/Developer" })
        #expect(client.recordVideoInvocation(udid: "U", path: "/m/r.mp4").commandLine
                == "xcrun simctl io U recordVideo --codec=h264 /m/r.mp4")
    }

    @Test func textSizeAndTheAppContainerPassTheExactArguments() async throws {
        fake.stub(["xcrun", "simctl", "ui", "U", "content_size"], stdout: "large\n")
        fake.stub(["xcrun", "simctl", "get_app_container"], stdout: "/Sims/U/data/Containers/Data/Application/A1\n")
        try await client.setTextSize(udid: "U", "accessibility-large")
        #expect(try await client.textSize(udid: "U") == "large")
        #expect(try await client.container(udid: "U", bundleId: "b.id", "data") == "/Sims/U/data/Containers/Data/Application/A1")
        #expect(fake.commandLines == [
            "xcrun simctl ui U content_size accessibility-large",
            "xcrun simctl ui U content_size",
            "xcrun simctl get_app_container U b.id data",
        ])
        #expect(SimctlClient.textSizes.count == 12 && SimctlClient.textSizes.first == "extra-small"
                && SimctlClient.textSizes.last == "accessibility-extra-extra-extra-large")
        // Seen on Xcode 27.0: simctl takes `extra-small` and `small`, and prints them back with a capital.
        fake.stub(["xcrun", "simctl", "ui", "U", "content_size"], stdout: "extra-Small\n")
        #expect(try await client.textSize(udid: "U") == "extra-small")
    }

    @Test func aContainerSimctlCannotFindSaysWhatToCheck() async throws {
        fake.stub(["xcrun", "simctl", "get_app_container"], exitCode: 2, stderr: LinkDeliveryTests.notInstalled)
        let error = await #expect(throws: XcdError.self) { _ = try await client.container(udid: "U", bundleId: "b.id", "data") }
        #expect(error?.code == .simulatorFailed && error?.message == "the simulator has no data container for b.id")
        #expect(error?.next == "install the app on this clone first (`xcd install` or `xcd run`), or name another app with --bundle <id>")
        // Seen on Xcode 27.0: for an app group the installed app does not have, simctl prints its usage and exits 117.
        fake.stub(["xcrun", "simctl", "get_app_container"], exitCode: 117, stderr: """
        Print the path of the installed app's container
        Usage: simctl get_app_container <device> <app bundle identifier> [<container>]
        """)
        let group = await #expect(throws: XcdError.self) {
            _ = try await client.container(udid: "U", bundleId: "b.id", "group.b.shared")
        }
        #expect(group?.message == "the simulator has no group.b.shared container for b.id")
        #expect(group?.next == "the app must be installed on this clone (`xcd install` or `xcd run`) and have that app group; "
                + "`xcd sim container groups` lists the groups it has")
    }

    /// Seen on a freshly booted clone: Safari was slow to launch, so simctl gave up with exit 60.
    static let timedOut = """
    An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=60):
    Simulator device failed to open https://example.com.
    Operation timed out
    Underlying error (domain=NSPOSIXErrorDomain, code=60):
    \tThe operation couldn’t be completed. Operation timed out
    \tOperation timed out
    """

    /// simctl gives up after about 10 s; on GitHub's runners Safari's first start on a clone took longer than two tries.
    @Test func openURLRetriesATimeoutUntilItOpens() async throws {
        let attempts = Counter()
        fake.stub(["xcrun", "simctl", "openurl"]) { _ in
            attempts.increment() < 6
                ? ProcessOutput(exitCode: 60, stdout: "", stderr: Self.timedOut)
                : ProcessOutput(exitCode: 0, stdout: "", stderr: "")
        }
        try await client.openURL(udid: "U", url: "https://example.com")
        #expect(attempts.value == 6)
    }

    @Test func openURLThatTimesOutSixTimesSaysTheSimulatorIsSlow() async throws {
        fake.stub(["xcrun", "simctl", "openurl"], exitCode: 60, stderr: Self.timedOut)
        let error = await #expect(throws: XcdError.self) { try await client.openURL(udid: "U", url: "https://example.com") }
        #expect(error?.code == .simulatorFailed && error?.message == "the simulator took too long to open https://example.com")
        #expect(error?.next == "the simulator may still be starting up; wait a few seconds and retry, or run `xcd doctor`")
        #expect(fake.calls.count == 6)
    }

    /// A timeout followed by another failure is that failure.
    @Test func openURLStopsRetryingAtAFailureThatIsNotATimeout() async throws {
        let attempts = Counter()
        fake.stub(["xcrun", "simctl", "openurl"]) { _ in
            attempts.increment() == 1
                ? ProcessOutput(exitCode: 60, stdout: "", stderr: Self.timedOut)
                : ProcessOutput(exitCode: 115, stdout: "", stderr: "(domain=LSApplicationWorkspaceErrorDomain, code=115)")
        }
        let error = await #expect(throws: XcdError.self) { try await client.openURL(udid: "U", url: "xcdsample://x") }
        #expect(error?.message == "the simulator could not open xcdsample://x" && attempts.value == 2)
    }

    @Test func openURLDoesNotRetryOtherFailures() async throws {
        fake.stub(["xcrun", "simctl", "openurl"], exitCode: 206, stderr: "Simulator device failed to open notaurl.")
        _ = await #expect(throws: XcdError.self) { try await client.openURL(udid: "U", url: "notaurl") }
        #expect(fake.calls.count == 1)
        fake.stub(["xcrun", "simctl", "openurl"], exitCode: 115, stderr: "(domain=LSApplicationWorkspaceErrorDomain, code=115)")
        _ = await #expect(throws: XcdError.self) { try await client.openURL(udid: "U", url: "xcdsample://x") }
        #expect(fake.calls.count == 2)
    }

    /// Seen on Xcode 27.
    @Test func failuresSayWhatToDo() async throws {
        fake.stub(["xcrun", "simctl", "openurl", "U", "notaurl"], exitCode: 206, stderr: """
        An error was encountered processing the command (domain=NSOSStatusErrorDomain, code=-50):
        Simulator device failed to open notaurl.
        """)
        fake.stub(["xcrun", "simctl", "openurl", "U", "xcdsample://x"], exitCode: 115, stderr: """
        An error was encountered processing the command (domain=LSApplicationWorkspaceErrorDomain, code=115):
        Simulator device failed to open xcdsample://x.
        """)
        fake.stub(["xcrun", "simctl", "push"], exitCode: 211, stderr: """
        An error was encountered processing the command (domain=UNErrorDomain, code=2003):
        Simulator device failed to complete the requested operation.
        Underlying error (domain=UNErrorDomain, code=2003):
        \tRepository could not save notification. Source is not authorized.
        """)
        fake.stub(["xcrun", "simctl", "privacy"], exitCode: 1, stderr: """
        An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=1):
        Simulator device failed to complete the requested operation.
        Operation not permitted
        """)
        let badURL = await #expect(throws: XcdError.self) { try await client.openURL(udid: "U", url: "notaurl") }
        #expect(badURL?.code == .simulatorFailed && badURL?.message == "the simulator could not open notaurl")
        #expect(badURL?.next == "pass a full URL with a scheme, e.g. https://example.com or myapp://path")
        let unhandled = await #expect(throws: XcdError.self) { try await client.openURL(udid: "U", url: "xcdsample://x") }
        #expect(unhandled?.next == "no app on this simulator opens xcdsample: URLs; install the app that registers it (`xcd install`), or check the URL")
        let push = await #expect(throws: XcdError.self) { try await client.push(udid: "U", bundleId: "b", payloadFile: "/p") }
        #expect(push?.next?.contains("Source is not authorized") == true && push?.next?.contains("`xcd install`") == true)
        let privacy = await #expect(throws: XcdError.self) {
            try await client.privacy(udid: "U", action: .grant, service: "bogus", bundleId: "b")
        }
        #expect(privacy?.code == .simulatorFailed)
        #expect(privacy?.next?.hasPrefix("simctl's documented services: all, calendar, contacts,") == true)
        #expect(privacy?.next?.hasSuffix("some unlisted ones, such as camera, also work") == true)
    }

    @Test func statusBarValuesAreCheckedBeforeSimctl() throws {
        #expect(throws: XcdError.self) { _ = try StatusBarOverrides(batteryLevel: 101).arguments() }
        #expect(throws: XcdError.self) { _ = try StatusBarOverrides(wifiBars: 4).arguments() }
        #expect(throws: XcdError.self) { _ = try StatusBarOverrides(cellularBars: -1).arguments() }
        let network = #expect(throws: XcdError.self) { _ = try StatusBarOverrides(network: "6g").arguments() }
        #expect(network?.code == .usage)
        #expect(network?.next == "use one of: hide, wifi, 3g, 4g, lte, lte-a, lte+, 5g, 5g+, 5g-uwb, 5g-uc")
        #expect(throws: XcdError.self) { _ = try StatusBarOverrides(batteryState: "full").arguments() }
        let empty = #expect(throws: XcdError.self) { _ = try StatusBarOverrides().arguments() }
        #expect(empty?.next == "pass at least one of --time, --battery, --battery-state, --wifi, --cellular, --network, --operator, or --clear")
        #expect(StatusBarOverrides(time: "9:41", batteryLevel: 100).summary == "time=9:41 battery=100")
    }

    @Test func coordinatesAreLatitudeCommaLongitude() throws {
        #expect(try Coordinate.parse("37.33,-122.03") == Coordinate(latitude: 37.33, longitude: -122.03))
        #expect(try Coordinate.parse(" 51.5 , -0.12 ") == Coordinate(latitude: 51.5, longitude: -0.12))
        for bad in ["nonsense", "91,0", "0,181", "1;2", "1,2,3"] {
            let error = #expect(throws: XcdError.self) { _ = try Coordinate.parse(bad) }
            #expect(error?.code == .usage)
        }
        #expect(Coordinate(latitude: 37.33, longitude: -122.03).text == "37.33,-122.03")
    }

    @Test func scaleComesFromTheDeviceTypesCapabilities() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd type \(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/Contents/Resources", withIntermediateDirectories: true)
        let plist: [String: Any] = ["capabilities": ["ScreenDimensionsCapability": [
            "main-screen-scale": 3, "main-screen-width": 1206, "main-screen-height": 2622]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: URL(fileURLWithPath: dir + "/Contents/Resources/capabilities.plist"))
        #expect(DeviceTypeProfile.scale(bundlePath: dir) == 3)
        #expect(DeviceTypeProfile.scale(bundlePath: dir + "/missing") == nil)
    }

    @Test func readsAPNGsPixelSize() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("xcd \(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: file) }
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        bytes += [0, 0, 0x04, 0xB6, 0, 0, 0x0A, 0x3E]          // 1206 x 2622
        try Data(bytes).write(to: URL(fileURLWithPath: file))
        let size = try #require(PNGInfo.size(of: file))
        #expect(size.width == 1206 && size.height == 2622)
        try Data("not a png".utf8).write(to: URL(fileURLWithPath: file))
        #expect(PNGInfo.size(of: file) == nil)
    }

    @Test func deviceTypesCarryTheirBundlePath() throws {
        let json = #"{"devicetypes":[{"name":"iPhone 18 Pro","identifier":"t","productFamily":"iPhone","bundlePath":"/L/iPhone 18 Pro.simdevicetype"}],"runtimes":[],"devices":{}}"#
        #expect(try SimCatalog.decode(Data(json.utf8)).deviceTypes.first?.bundlePath == "/L/iPhone 18 Pro.simdevicetype")
    }
}
