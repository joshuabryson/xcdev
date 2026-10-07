import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The pieces a link is delivered with: the scheme approval, the process lookup, and the scheme check.
@Suite struct LinkDeliveryTests {
    let fake = FakeProcessRunner()
    var simctl: SimctlClient { SimctlClient(runner: fake, developerDir: "/X.app/Contents/Developer", sleep: { _ in }) }
    let product = AppProduct(path: "/dd/SampleApp.app", bundleId: "dev.xcdev.SampleApp", executableName: "SampleApp",
                             platform: "iphonesimulator")
    static let container = "/sims/U1/data/Containers/Bundle/Application/AB12/SampleApp.app"
    /// What simctl prints for an app that is not installed (seen on iOS 27.0).
    static let notInstalled = """
    An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=2):
    The operation couldn’t be completed. No such file or directory
    No such file or directory
    """

    @Test func theApprovalIsWrittenForTheSchemeAsTheLinkSpellsIt() async throws {
        fake.stub(["xcrun", "simctl", "spawn"])
        try await simctl.approveScheme(udid: "U1", scheme: "MyApp", bundleId: "dev.x.App")
        #expect(fake.calls.map(\.arguments) == [["simctl", "spawn", "U1", "defaults", "write", "com.apple.launchservices.schemeapproval",
                                                 "com.apple.CoreSimulator.CoreSimulatorBridge-->MyApp", "-string", "dev.x.App"]])
        #expect(fake.calls[0].environment["DEVELOPER_DIR"] == "/X.app/Contents/Developer")
        fake.stub(["xcrun", "simctl", "spawn"], exitCode: 149, stderr: "Unable to lookup in current state: Shutdown")
        let error = await #expect(throws: XcdError.self) { try await simctl.approveScheme(udid: "U1", scheme: "a", bundleId: "b") }
        #expect(error?.code == .simulatorFailed && error?.next == "boot the simulator with `xcd sim boot`, then retry")
    }

    @Test func theAppContainerIsWhereTheSimulatorInstalledTheApp() async throws {
        fake.stub(["xcrun", "simctl", "get_app_container"], stdout: Self.container + "\n")
        #expect(try await simctl.appContainer(udid: "U1", bundleId: "dev.x.App") == Self.container)
        #expect(fake.calls[0].arguments == ["simctl", "get_app_container", "U1", "dev.x.App", "app"])
        fake.stub(["xcrun", "simctl", "get_app_container"], exitCode: 2, stderr: Self.notInstalled)
        #expect(try await simctl.appContainer(udid: "U1", bundleId: "dev.x.App") == nil)
        fake.stub(["xcrun", "simctl", "get_app_container"], exitCode: 148, stderr: "Invalid device: U1")
        let error = await #expect(throws: XcdError.self) { _ = try await simctl.appContainer(udid: "U1", bundleId: "b") }
        #expect(error?.code == .simulatorFailed)
    }

    @Test func aProcessIsFoundByTheExactPathOfItsExecutable() async throws {
        let exe = Self.container + "/SampleApp"
        fake.stub(["ps"], stdout: """
              1 /sbin/launchd
            300 \(exe)
            301 \(Self.container)/SampleApp Helper
            302 /other/SampleApp.app/SampleApp
           4000 \(exe)
        """)
        #expect(try await ProcessLookup(runner: fake).pids(of: exe) == [300, 4000])
        #expect(try await ProcessLookup(runner: fake).pids(of: "/nope/SampleApp").isEmpty)
        #expect(fake.calls[0].argv == ["ps", "-axo", "pid=,comm="] && fake.calls[0].timeout == .seconds(30))
    }

    /// `ps` and the build can name one file two ways: through a link, or with and without `/private`.
    @Test func pathsAreComparedInCanonicalForm() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd lookup \(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/real/App.app", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/real/App.app/App", contents: Data())
        try FileManager.default.createSymbolicLink(atPath: dir + "/link", withDestinationPath: dir + "/real")
        fake.stub(["ps"], stdout: "  77 \(dir)/link/App.app/App\n  78 /private\(dir)/real/App.app/App\n")
        #expect(try await ProcessLookup(runner: fake).pids(of: dir + "/real/App.app/App") == [77, 78])
    }

    @Test func aSimulatorAppIsRunningWhenAProcessRunsFromItsContainer() async throws {
        let host = SimulatorAppHost(simctl: simctl, udid: "U1")
        fake.stub(["xcrun", "simctl", "get_app_container"], stdout: Self.container + "\n")
        fake.stub(["ps"], stdout: "  10 /dd/SampleApp.app/SampleApp\n  300 \(Self.container)/SampleApp\n")
        #expect(try await host.runningPid(product) == 300)                  // the installed copy, not the build folder's
        fake.stub(["ps"], stdout: "  10 /dd/SampleApp.app/SampleApp\n")
        #expect(try await host.runningPid(product) == nil)
        fake.stub(["xcrun", "simctl", "get_app_container"], exitCode: 2, stderr: Self.notInstalled)
        let error = await #expect(throws: XcdError.self) { _ = try await host.runningPid(product) }
        #expect(error?.code == .simulatorFailed && error?.message == "dev.xcdev.SampleApp is not installed on this simulator")
        #expect(error?.next == "install and start it with `xcd run`")
    }

    @Test func aCustomSchemeIsApprovedBeforeItsLinkIsSent() async throws {
        fake.stub(["xcrun", "simctl"])
        let host = SimulatorAppHost(simctl: simctl, udid: "U1")
        try await host.open("SampleApp://item?id=1", in: product)
        #expect(fake.commandLines == [
            "xcrun simctl spawn U1 defaults write com.apple.launchservices.schemeapproval 'com.apple.CoreSimulator.CoreSimulatorBridge-->SampleApp' -string dev.xcdev.SampleApp",
            "xcrun simctl openurl U1 'SampleApp://item?id=1'",
        ])
    }

    /// An https link goes through the system like a tapped one. There is nothing to approve.
    @Test func aWebLinkIsSentWithoutAnApproval() async throws {
        fake.stub(["xcrun", "simctl"])
        try await SimulatorAppHost(simctl: simctl, udid: "U1").open("https://example.com/a", in: product)
        try await SimulatorAppHost(simctl: simctl, udid: "U1").open("HTTP://example.com/a", in: product)
        #expect(fake.commandLines == ["xcrun simctl openurl U1 https://example.com/a", "xcrun simctl openurl U1 HTTP://example.com/a"])
    }

    @Test func aMacAppIsFoundByItsBuildPathAndTakesNoLinksYet() async throws {
        let mac = AppProduct(path: "/dd/Mac App.app", bundleId: "dev.x.Mac", executableName: "Mac App", platform: "macosx")
        fake.stub(["ps"], stdout: "  100 \(mac.executablePath)\n  300 \(mac.executablePath)\n  400 /other\n")
        let host = MacAppHost(runner: fake, sleep: { _ in })
        #expect(try await host.runningPid(mac) == 300)
        let error = await #expect(throws: XcdError.self) { try await host.open("myapp://x", in: mac) }
        #expect(error?.code == .platformUnsupported && error?.message == "`xcd open` cannot deliver to a Mac app yet")
        #expect(error?.next == "until it can, send the link yourself: /usr/bin/open -g -a '/dd/Mac App.app' myapp://x")
    }
}

/// The scheme check, against a real Info.plist on disk.
@Suite struct AppSchemesTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd schemes \(UUID().uuidString)").path

    /// Writes an app bundle whose Info.plist registers `schemes`, in two URL types, and returns its product.
    func app(schemes: [[String]], mac: Bool = false, binary: Bool = false) throws -> AppProduct {
        let path = dir + "/App.app"
        let plistDir = mac ? path + "/Contents" : path
        try FileManager.default.createDirectory(atPath: plistDir, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "dev.x.App",
                                    "CFBundleURLTypes": schemes.map { ["CFBundleURLName": "n", "CFBundleURLSchemes": $0] }]
        try PropertyListSerialization.data(fromPropertyList: plist, format: binary ? .binary : .xml, options: 0)
            .write(to: URL(fileURLWithPath: plistDir + "/Info.plist"))
        return AppProduct(path: path, bundleId: "dev.x.App", executableName: "App", platform: mac ? "macosx" : "iphonesimulator")
    }

    @Test func schemesAreReadFromEveryURLType() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(AppSchemes.registered(by: try app(schemes: [["myapp", "MyCaps"], ["other"]])) == ["myapp", "MyCaps", "other"])
        #expect(AppSchemes.registered(by: try app(schemes: [["bin"]], binary: true)) == ["bin"])       // a built app's plist is binary
        #expect(AppSchemes.registered(by: try app(schemes: [])) == [])
    }

    @Test func aMacAppKeepsItsPlistUnderContents() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(AppSchemes.registered(by: try app(schemes: [["macapp"]], mac: true)) == ["macapp"])
    }

    @Test func anUnreadablePlistIsUnknownNotEmpty() {
        let missing = AppProduct(path: dir + "/Nope.app", bundleId: "b", executableName: "N", platform: "iphonesimulator")
        #expect(AppSchemes.registered(by: missing) == nil)
    }

    @Test func aSchemeTheAppDoesNotRegisterIsRefused() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let product = try app(schemes: [["myapp", "MyCaps"]])
        try RouteErrors.checkScheme("myapp://x", registeredBy: product)
        try RouteErrors.checkScheme("MYAPP://x", registeredBy: product)          // the system ignores case here
        try RouteErrors.checkScheme("mycaps://x", registeredBy: product)
        try RouteErrors.checkScheme("https://example.com", registeredBy: product)     // web links are the system's to route
        let error = #expect(throws: XcdError.self) { try RouteErrors.checkScheme("other://x", registeredBy: product) }
        #expect(error?.code == .usage && error?.message == "dev.x.App does not register the scheme 'other'")
        #expect(error?.next == "it registers: myapp, MyCaps; for a link meant for another app, use `xcd sim open-url`")
        let none = try app(schemes: [])
        let empty = #expect(throws: XcdError.self) { try RouteErrors.checkScheme("myapp://x", registeredBy: none) }
        #expect(empty?.next?.hasPrefix("the built app registers no URL scheme") == true)
    }

    @Test func anAppWhosePlistCannotBeReadIsNotChecked() throws {
        let missing = AppProduct(path: dir + "/Nope.app", bundleId: "b", executableName: "N", platform: "iphonesimulator")
        try RouteErrors.checkScheme("anything://x", registeredBy: missing)
    }

    @Test func routeFailedIsATaskFailure() {
        #expect(ErrorCode.routeFailed.rawValue == "route_failed" && ErrorCode.routeFailed.exitCode == 1)
        #expect(ErrorsReport().text.contains("\nroute_failed            1  A route's script failed, or its link did not start the app.\n"))
        let web = RouteErrors.notStarted("https://example.com/a", AppProduct(path: "/a", bundleId: "dev.x.App", executableName: "A", platform: "iphonesimulator"))
        #expect(web.code == .routeFailed && web.message == "the link was sent, but it did not start dev.x.App within 30s")
        #expect(web.next?.hasSuffix("an https link opens in Safari unless the app's associated domains work on this simulator") == true)
        #expect(web.details == ["url: https://example.com/a"])
    }
}
