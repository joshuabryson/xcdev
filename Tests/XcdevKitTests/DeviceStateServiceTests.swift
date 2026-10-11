import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct DeviceStateServiceTests {
    let worktree = FakeWorktree(prefix: "xcd state")
    let yaml = """
    version: 1
    project: App.xcodeproj
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro" }
      mac: { platform: macOS }
    """

    func setup() throws -> (DeviceStateService, WorktreeContext) {
        _ = try FakeSimulators(runner: worktree.runner, catalogJSON: Fixture.string("simctl-list.json"))
        for sub in ["openurl", "push", "privacy", "status_bar", "ui", "location", "pbcopy", "addmedia"] {
            worktree.runner.stub(["xcrun", "simctl", sub])
        }
        worktree.runner.stub(["xcrun", "simctl", "pbpaste"], stdout: "copied")
        return (DeviceStateService(provisioner: worktree.provisioner, now: { Date(timeIntervalSince1970: 1_791_085_501) }),
                try worktree.context(yaml))
    }

    func built(_ ctx: WorktreeContext, bundle: String = "dev.xcdev.App") throws {
        var state = AppState()
        state.builds["iphone"] = BuildRecord(scheme: "App", configuration: nil,
                                             product: AppProduct(path: "/A.app", bundleId: bundle, executableName: "App", platform: "iphonesimulator"),
                                             finishedAt: Date())
        try AppStateStore.save(state, ctx.paths)
    }

    func last(_ sub: String) -> Invocation? { worktree.runner.calls.last { $0.arguments.dropFirst().first == sub } }

    @Test func eachCommandBootsTheCloneAndReports() async throws {
        defer { worktree.remove() }
        var (svc, ctx) = try setup()
        let report = try await svc.openURL("myapp://home", device: nil, in: &ctx)
        #expect(report.text.hasPrefix("opened myapp://home  device=iphone  udid="))
        #expect(worktree.runner.commandLines.contains { $0.contains("simctl bootstatus") })
        _ = try await svc.statusBar(StatusBarOverrides(time: "9:41"), device: nil, in: &ctx)
        #expect(try await svc.statusBar(nil, device: nil, in: &ctx).action == "cleared the status bar")
        #expect(try await svc.appearance(.dark, device: nil, in: &ctx).action == "set appearance to dark")
        #expect(try await svc.location(Coordinate(latitude: 1, longitude: 2), device: nil, in: &ctx).action == "set location to 1.0,2.0")
        #expect(try await svc.location(nil, device: nil, in: &ctx).action == "cleared the location")
    }

    @Test func bundleIdsComeFromTheLastBuildOrBundle() async throws {
        defer { worktree.remove() }
        var (svc, ctx) = try setup()
        let unbuilt = await #expect(throws: XcdError.self) {
            _ = try await svc.privacy(.grant, service: "photos", bundle: nil, device: nil, in: &ctx)
        }
        #expect(unbuilt?.code == .appNotBuilt)
        #expect(unbuilt?.next == "pass --bundle <id>, or build first with `xcd build --device iphone`")
        try built(ctx)
        #expect(try await svc.privacy(.grant, service: "photos", bundle: nil, device: nil, in: &ctx).action
                == "granted photos to dev.xcdev.App")
        #expect(last("privacy")?.arguments.suffix(3) == ["grant", "photos", "dev.xcdev.App"])
        _ = try await svc.privacy(.revoke, service: "camera", bundle: "other.app", device: nil, in: &ctx)
        #expect(last("privacy")?.arguments.last == "other.app")
    }

    @Test func resetWithoutABuildResetsEveryApp() async throws {
        defer { worktree.remove() }
        var (svc, ctx) = try setup()
        #expect(try await svc.privacy(.reset, service: "all", bundle: nil, device: nil, in: &ctx).action == "reset all for every app")
        #expect(last("privacy")?.arguments.suffix(2) == ["reset", "all"])
    }

    @Test func pushWritesAnAlertPayloadOrUsesAFile() async throws {
        defer { worktree.remove() }
        var (svc, ctx) = try setup()
        try built(ctx)
        _ = try await svc.push(alert: "Hello \"you\"", file: nil, bundle: nil, device: nil, in: &ctx)
        let payload = try #require(last("push")?.arguments.last)
        #expect(payload.hasPrefix(ctx.paths.results + "/") && payload.hasSuffix("-push.json"))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: payload))) as? [String: Any]
        #expect((json?["aps"] as? [String: Any])?["alert"] as? String == "Hello \"you\"")
        let both = await #expect(throws: XcdError.self) { _ = try await svc.push(alert: "a", file: "/f", bundle: nil, device: nil, in: &ctx) }
        #expect(both?.code == .usage && both?.next == "pass either --alert <text> or --file <payload.json>")
        let missing = await #expect(throws: XcdError.self) { _ = try await svc.push(alert: nil, file: "/nope.json", bundle: nil, device: nil, in: &ctx) }
        #expect(missing?.code == .usage)
    }

    @Test func addmediaChecksFilesBeforeSimctlCrashesOnThem() async throws {
        defer { worktree.remove() }
        var (svc, ctx) = try setup()
        let error = await #expect(throws: XcdError.self) { _ = try await svc.addMedia(["/no/such.png"], device: nil, in: &ctx) }
        #expect(error?.code == .usage && error?.message == "/no/such.png doesn't exist")
        #expect(last("addmedia") == nil)
    }

    /// simctl exits 0 for text the simulator did not keep, so the pasteboard is read back before success is reported.
    @Test func thePasteboardRoundTripsText() async throws {
        defer { worktree.remove() }
        var (svc, ctx) = try setup()
        let set = try await svc.setPasteboard(text: "copied", device: nil, in: &ctx)
        #expect(set.text.hasPrefix("set the pasteboard (6 characters)  device=iphone  udid="))
        let input = try #require(last("pbcopy")?.inputFile)
        #expect(!FileManager.default.fileExists(atPath: input))            // the temporary file is deleted afterwards
        #expect(worktree.runner.calls.suffix(2).map { $0.arguments.dropFirst().first } == ["pbcopy", "pbpaste"])
        let got = try await svc.pasteboard(device: nil, in: &ctx)
        #expect(got.text == "copied" && Renderer.report(got, command: "sim pasteboard get", format: .text) == "copied")
    }

    /// Seen on iOS 27.0 once Device Hub had started its pasteboard sync with the simulator: `simctl pbcopy` exited
    /// 0, the simulator logged "Ignoring snapshot for com.apple.UIKit.pboard.general: the CoreDevice pasteboard stack
    /// is in use", and its pasteboard went on holding what the Mac's clipboard had put there.
    @Test func textTheSimulatorDidNotKeepIsAFailureThatSaysWhy() async throws {
        defer { worktree.remove() }
        var (svc, ctx) = try setup()
        worktree.runner.stub(["xcrun", "simctl", "pbpaste"], stdout: "what the person at the Mac copied last")
        worktree.runner.stub(["pgrep", "-x", "DeviceHub"], stdout: "10551\n")
        let shared = await #expect(throws: XcdError.self) { _ = try await svc.setPasteboard(text: "hello", device: nil, in: &ctx) }
        let udid = try #require(last("pbcopy")?.arguments.last)
        #expect(shared?.code == .simulatorFailed && shared?.message == "simctl reported success, but iphone's pasteboard does not hold the text")
        #expect(shared?.next == "Device Hub is open, and while it is, a simulator shares its pasteboard with the Mac's clipboard and drops text "
            + "that simctl sends. To put text into a field, use `xcd ui type`. `xcrun devicectl device pasteboard copy --device \(udid) "
            + "--file <file>` does set the pasteboard, and it replaces the Mac's clipboard with the same text, so ask the person at the Mac first")
        // What the pasteboard holds instead may be the person's own, and is shown to nobody.
        #expect(shared.map { ($0.message + ($0.next ?? "") + $0.details.joined()).contains("copied last") } == false)

        worktree.runner.stub(["pgrep", "-x", "DeviceHub"], exitCode: 1)
        let unexplained = await #expect(throws: XcdError.self) { _ = try await svc.setPasteboard(text: "hello", device: nil, in: &ctx) }
        #expect(unexplained?.code == .simulatorFailed && unexplained?.message == shared?.message)
        #expect(unexplained?.next == "run `xcd doctor`")
    }

    /// Not a character more or less: text that differs only by a newline at its end is not the text that was set.
    @Test func textThatCameBackWithANewlineAddedIsNotTheTextThatWasSet() async throws {
        defer { worktree.remove() }
        var (svc, ctx) = try setup()
        worktree.runner.stub(["pgrep", "-x", "DeviceHub"], exitCode: 1)
        worktree.runner.stub(["xcrun", "simctl", "pbpaste"], stdout: "two\nlines\n")
        #expect(try await svc.setPasteboard(text: "two\nlines\n", device: nil, in: &ctx).action == "set the pasteboard (10 characters)")
        await #expect(throws: XcdError.self) { _ = try await svc.setPasteboard(text: "two\nlines", device: nil, in: &ctx) }
    }

    /// A link for this worktree's own app would stop at an "Open in …?" alert on a clone that never opened its scheme.
    @Test func openURLApprovesASchemeTheBuiltAppRegisters() async throws {
        defer { worktree.remove() }
        var (svc, ctx) = try setup()
        worktree.runner.stub(["xcrun", "simctl", "spawn"])
        let app = worktree.root + "/Build/App.app"
        try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleURLTypes": [["CFBundleURLSchemes": ["myapp"]]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: app + "/Info.plist"))
        var state = AppState()
        state.builds["iphone"] = BuildRecord(scheme: "App", configuration: nil,
                                             product: AppProduct(path: app, bundleId: "dev.xcdev.App", executableName: "App", platform: "iphonesimulator"),
                                             finishedAt: Date())
        try AppStateStore.save(state, ctx.paths)

        _ = try await svc.openURL("MyApp://home", device: nil, in: &ctx)
        #expect(last("spawn")?.arguments.suffix(3) == ["com.apple.CoreSimulator.CoreSimulatorBridge-->MyApp", "-string", "dev.xcdev.App"])
        let approved = try #require(worktree.runner.calls.lastIndex { $0.arguments.dropFirst().first == "spawn" })
        let sent = try #require(worktree.runner.calls.lastIndex { $0.arguments.dropFirst().first == "openurl" })
        #expect(approved < sent)
        // Links for other apps, and web links, are sent as before.
        let approvals = worktree.runner.calls.filter { $0.arguments.dropFirst().first == "spawn" }.count
        _ = try await svc.openURL("other://home", device: nil, in: &ctx)
        _ = try await svc.openURL("https://example.com", device: nil, in: &ctx)
        #expect(worktree.runner.calls.filter { $0.arguments.dropFirst().first == "spawn" }.count == approvals)
        #expect(last("openurl")?.arguments.last == "https://example.com")
    }

    @Test func theTextSizeIsSetOrRead() async throws {
        defer { worktree.remove() }
        var (svc, ctx) = try setup()
        worktree.runner.stub(["xcrun", "simctl", "ui"], stdout: "accessibility-large\n")
        let set = try await svc.textSize("accessibility-large", device: nil, in: &ctx)
        #expect(set.text.hasPrefix("set text size to accessibility-large  device=iphone  udid=") && set.changed)
        // The size is set, then read back: the report says what the device has now.
        let sizes = worktree.runner.calls.filter { $0.arguments.dropFirst().first == "ui" }.map { $0.arguments.dropFirst(3).joined(separator: " ") }
        #expect(sizes == ["content_size accessibility-large", "content_size"])
        let calls = worktree.runner.calls.count
        let read = try await svc.textSize(nil, device: nil, in: &ctx)
        #expect(read.text.hasPrefix("text size is accessibility-large  device=iphone  udid=") && !read.changed)
        #expect(read.size == "accessibility-large" && last("ui")?.arguments.last == "content_size")
        // A size simctl does not know is refused before the clone is booted.
        let before = worktree.runner.calls.count
        let bad = await #expect(throws: XcdError.self) { _ = try await svc.textSize("huge", device: nil, in: &ctx) }
        #expect(bad?.code == .usage && bad?.message == "'huge' is not a text size" && worktree.runner.calls.count == before)
        #expect(bad?.next == "use one of: " + SimctlClient.textSizes.joined(separator: ", "))
        #expect(before > calls)
    }

    @Test func theContainerIsTheBuiltAppsDataFolderUnlessAnotherIsNamed() async throws {
        defer { worktree.remove() }
        var (svc, ctx) = try setup()
        worktree.runner.stub(["xcrun", "simctl", "get_app_container"]) { invocation in
            let kind = invocation.arguments.last ?? ""
            let groups = "group.dev.xcdev.shared\t/G/shared\ngroup.dev.xcdev.other\t/G/other\n"
            return ProcessOutput(exitCode: 0, stdout: kind == "groups" ? groups : "/C/\(kind)\n", stderr: "")
        }
        let unbuilt = await #expect(throws: XcdError.self) { _ = try await svc.container(nil, bundle: nil, device: nil, in: &ctx) }
        #expect(unbuilt?.code == .appNotBuilt && last("get_app_container") == nil)
        try built(ctx)
        let data = try await svc.container(nil, bundle: nil, device: nil, in: &ctx)
        #expect(data.path == "/C/data" && data.container == "data" && data.bundleId == "dev.xcdev.App" && data.groups == nil)
        #expect(Renderer.report(data, command: "sim container", format: .text) == "/C/data")     // the path alone, for `$(…)`
        #expect(last("get_app_container")?.arguments.suffix(2) == ["dev.xcdev.App", "data"])
        let app = try await svc.container("app", bundle: "other.app", device: nil, in: &ctx)
        #expect(app.path == "/C/app" && last("get_app_container")?.arguments.suffix(2) == ["other.app", "app"])
        #expect(try await svc.container("group.dev.xcdev.shared", bundle: nil, device: nil, in: &ctx).path == "/C/group.dev.xcdev.shared")
        let groups = try await svc.container("groups", bundle: nil, device: nil, in: &ctx)
        #expect(groups.path == nil && groups.groups == ["group.dev.xcdev.shared": "/G/shared", "group.dev.xcdev.other": "/G/other"])
        #expect(groups.text == "group.dev.xcdev.other\t/G/other\ngroup.dev.xcdev.shared\t/G/shared")
    }

    @Test func anAppWithNoAppGroupsSaysSo() async throws {
        defer { worktree.remove() }
        var (svc, ctx) = try setup()
        worktree.runner.stub(["xcrun", "simctl", "get_app_container"])
        try built(ctx)
        let groups = try await svc.container("groups", bundle: nil, device: nil, in: &ctx)
        #expect(groups.groups == [:] && groups.text == "dev.xcdev.App has no app groups")
    }

    @Test func aMacDeviceHasNoSimulator() async throws {
        defer { worktree.remove() }
        var (svc, ctx) = try setup()
        let error = await #expect(throws: XcdError.self) { _ = try await svc.openURL("https://x", device: "mac", in: &ctx) }
        #expect(error?.code == .usage)
    }
}
