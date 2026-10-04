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

    @Test func thePasteboardRoundTripsText() async throws {
        defer { worktree.remove() }
        var (svc, ctx) = try setup()
        _ = try await svc.setPasteboard(text: "hello", device: nil, in: &ctx)
        let input = try #require(last("pbcopy")?.inputFile)
        #expect(!FileManager.default.fileExists(atPath: input))            // the temporary file is deleted afterwards
        let got = try await svc.pasteboard(device: nil, in: &ctx)
        #expect(got.text == "copied" && Renderer.report(got, command: "sim pasteboard get", format: .text) == "copied")
    }

    @Test func aMacDeviceHasNoSimulator() async throws {
        defer { worktree.remove() }
        var (svc, ctx) = try setup()
        let error = await #expect(throws: XcdError.self) { _ = try await svc.openURL("https://x", device: "mac", in: &ctx) }
        #expect(error?.code == .usage)
    }
}
