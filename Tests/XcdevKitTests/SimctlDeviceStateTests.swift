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
