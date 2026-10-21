import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd ui` on a Mac device.
@Suite struct UIServiceMacTests {
    let worktree = FakeWorktree(prefix: "xcd ui mac")
    static let yaml = """
    version: 1
    project: App.xcodeproj
    defaultDevice: mac
    devices:
      mac: { platform: macOS }
      iphone: { type: "iPhone 18 Pro" }
    """
    var product: AppProduct { AppProduct(path: worktree.root + "/Build/Products/Debug/Mac.app", bundleId: "dev.x.Mac", executableName: "Mac", platform: "macosx") }
    let options = UIOptions(device: nil, bundle: nil, system: false, role: nil, index: nil, timeout: .seconds(1))
    static var app: FakeApp { FakeApp(windows: [MacSnapshotTests.window([MacSnapshotTests.text, MacSnapshotTests.button, MacSnapshotTests.field])], hidden: true) }

    /// `running`: the pids `ps` lists for the build's executable; `bundles`: what `--bundle <id>` finds running.
    func setup(_ api: FakeAccessibility, running: [Int32] = [7], bundles: [String: [Int32]] = [:],
               locked: Bool = false) throws -> (UIService, WorktreeContext) {
        let ctx = try worktree.context(Self.yaml, container: "App.xcodeproj")
        var state = AppState()
        state.builds["mac"] = BuildRecord(scheme: "App", configuration: nil, product: product, finishedAt: Date())
        try AppStateStore.save(state, ctx.paths)
        let product = product
        worktree.runner.stub(["ps"]) { _ in ProcessOutput(stdout: running.map { "  \($0) \(product.executablePath)\n" }.joined()) }
        let provisioner = worktree.provisioner
        let supervisor = RunnerSupervisor(provisioner: provisioner,
                                          builder: RunnerBuilder(runner: worktree.runner, globalPaths: provisioner.globalPaths),
                                          detached: FakeDetachedProcesses(), client: RunnerClient(transport: FakeRunnerTransport()),
                                          globalPaths: provisioner.globalPaths, sleep: Instant.sleep)
        let service = UIService(supervisor: supervisor, client: supervisor.client,
                                crashes: CrashReportLocator(directory: worktree.root + "/DiagnosticReports"),
                                accessibility: { api }, hostApp: { "iTerm" }, running: { bundles[$0] ?? [] }, screenLocked: { locked })
        return (service, ctx)
    }

    @Test func theTreeComesFromTheAccessibilityApiAndSaysHidden() async throws {
        defer { worktree.remove() }
        var (service, ctx) = try setup(FakeAccessibility(app: Self.app))
        let report = try await service.tree(all: false, options, in: &ctx)
        #expect(report.tree.hidden == true && report.udid == "pid 7" && report.tree.elements.map(\.identifier).contains("increment"))
        #expect(report.text.hasPrefix("running (hidden)") && report.text.contains("window: Probe 900x552 @2x"))
        #expect(FileManager.default.fileExists(atPath: MacRefStore.file(ctx.paths, device: "mac")))
    }

    @Test func aRefSurvivesACommandAndDiesWithARelaunch() async throws {
        defer { worktree.remove() }
        let api = FakeAccessibility(app: Self.app)
        var (service, ctx) = try setup(api)
        let tree = try await service.tree(all: false, options, in: &ctx)
        let ref = try #require(tree.tree.elements.first { $0.identifier == "increment" }?.ref)
        let tapped = try await service.tap(ref, options, in: &ctx)
        #expect(tapped.element?.identifier == "increment" && api.events.contains("AXPress increment"))
        MacRefStore.forgetAll(in: ctx.paths)                               // what `xcd run` does
        let stale = await #expect(throws: XcdError.self) { try await service.tap(ref, options, in: &ctx) }
        #expect(stale?.code == .staleRef && stale?.message.contains("not a ref of the latest tree") == true)
    }

    @Test func typingFocusesTheFieldClearsItPostsTheKeysAndSubmits() async throws {
        defer { worktree.remove() }
        let api = FakeAccessibility(app: Self.app)
        var (service, ctx) = try setup(api)
        let typed = try await service.type("hi", TypeOptions(into: "id:name", clear: true, submit: true), options, in: &ctx)
        #expect(typed.text.hasPrefix("typed 2 characters into") && typed.text.contains("id=name"))
        #expect(typed.text.contains("by keyboard, after clearing, then Return"))
        #expect(api.events == ["set AXFocused name bool(true)", "set AXValue name string(\"\")", "key 51", "key \"h\"", "key \"i\"", "key 36"])
    }

    @Test func withoutAccessibilityEveryCommandIsPermissionMissingNamingTheHostApp() async throws {
        defer { worktree.remove() }
        let api = FakeAccessibility(app: Self.app)
        api.setTrusted(false, capture: true)
        var (service, ctx) = try setup(api, running: [])                  // the grant is checked before the app is looked for
        let error = await #expect(throws: XcdError.self) { try await service.tree(all: false, options, in: &ctx) }
        #expect(error?.code == .permissionMissing && error?.message.hasPrefix("iTerm has no Accessibility permission") == true)
        #expect(error?.code.exitCode == 3 && !worktree.runner.calls.contains { $0.argv[0] == "ps" })
    }

    /// With the screen locked, a hidden app's windows collapse into a loop, so nothing is read, granted or not. Only
    /// `--system` is refused before the lock: that is the invocation's fault whatever the Mac's state.
    @Test func aLockedScreenIsRefusedBeforeThePermissionsAndThePid() async throws {
        defer { worktree.remove() }
        let api = FakeAccessibility(app: Self.app)
        api.setTrusted(false, capture: false)
        var (service, ctx) = try setup(api, running: [], locked: true)
        let locked = await #expect(throws: XcdError.self) { try await service.tap("id:increment", options, in: &ctx) }
        #expect(locked?.code == .runnerFailed && locked?.message == "the Mac's screen is locked, so the app's windows cannot be read")
        #expect(locked?.next == "ask the user to unlock the Mac, then run the command again")
        #expect(api.events.isEmpty && !worktree.runner.calls.contains { $0.argv[0] == "ps" })
    }

    @Test func anAppThatIsNotRunningSaysSoAndSystemIsRefused() async throws {
        defer { worktree.remove() }
        var (service, ctx) = try setup(FakeAccessibility(app: Self.app), running: [])
        let gone = await #expect(throws: XcdError.self) { try await service.tree(all: false, options, in: &ctx) }
        #expect(gone?.code == .elementNotFound && gone?.message == "the app is not running on this Mac" && gone?.next?.contains("xcd run") == true)
        var system = options
        system.system = true
        let refused = await #expect(throws: XcdError.self) { try await service.tree(all: false, system, in: &ctx) }
        #expect(refused?.code == .platformUnsupported)
    }

    @Test func anAppThatExitsDuringAnActionIsAppCrashed() async throws {
        defer { worktree.remove() }
        let api = FakeAccessibility(app: Self.app)
        api.exitAfterNextPress()
        var (service, ctx) = try setup(api)
        let crashed = await #expect(throws: XcdError.self) { try await service.tap("id:increment", options, in: &ctx) }
        #expect(crashed?.code == .appCrashed && crashed?.message.contains("no crash report found") == true)
    }

    /// A crash report written by a simulator's app of the same name.
    func writeCrashReport(ranIn simulator: String?) throws {
        let dir = worktree.root + "/DiagnosticReports"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Fixture.crashReport(in: simulator).write(toFile: dir + "/Mac-2026-10-20-19000\(simulator == nil ? 1 : 0).ips", atomically: true, encoding: .utf8)
    }

    /// The report is looked for among the Mac's own: one from a simulator's app of the same name is another app's.
    @Test func aCrashDuringAnActionIsLookedForAmongTheMacsReports() async throws {
        defer { worktree.remove() }
        try writeCrashReport(ranIn: "5A1B2C3D-0000-4000-8000-000000000000")
        for written in [false, true] {
            let api = FakeAccessibility(app: Self.app)
            api.exitAfterNextPress()
            var (service, ctx) = try setup(api)
            if written { try writeCrashReport(ranIn: nil) }
            let crashed = await #expect(throws: XcdError.self) { try await service.tap("id:increment", options, in: &ctx) }
            #expect(crashed?.message.hasPrefix(written ? "the app crashed during the tap: " : "the app stopped running during the tap (no crash report found)") == true)
        }
    }

    /// The walk stops at depth 40; the session carries that onto the tree, and the printed tree says so.
    @Test func aTreeCutAtTheDepthCapSaysSo() async throws {
        defer { worktree.remove() }
        var deep = MacSnapshotTests.button
        for _ in 0..<45 { deep = FakeNode(role: "AXGroup", frame: ScreenRect(x: 2574, y: 323, w: 85, h: 24), children: [deep]) }
        var (service, ctx) = try setup(FakeAccessibility(app: FakeApp(windows: [MacSnapshotTests.window([deep])], hidden: true)))
        let report = try await service.tree(all: false, options, in: &ctx)
        #expect(report.tree.capped == true && report.text.hasSuffix("\n" + UIText.cappedNote))
    }

    @Test func aPointSwipeIsRefusedOnAMac() async throws {
        defer { worktree.remove() }
        var (service, ctx) = try setup(FakeAccessibility(app: Self.app))
        let refused = await #expect(throws: XcdError.self) {
            try await service.swipe(SwipeOptions(direction: nil, on: nil, from: "10,10", to: "10,100"), options, in: &ctx)
        }
        #expect(refused?.code == .platformUnsupported && refused?.next?.contains("--on") == true)
    }

    @Test func aBundleIdMustNameExactlyOneRunningApp() async throws {
        defer { worktree.remove() }
        var (service, ctx) = try setup(FakeAccessibility(app: Self.app), running: [], bundles: ["dev.other": []])
        var bundled = options
        bundled.bundle = "dev.other"
        let none = await #expect(throws: XcdError.self) { try await service.tree(all: false, bundled, in: &ctx) }
        #expect(none?.code == .usage && none?.message == "no running app has the bundle id dev.other")
        (service, ctx) = try setup(FakeAccessibility(app: Self.app), running: [], bundles: ["dev.other": [11, 12]])
        let two = await #expect(throws: XcdError.self) { try await service.tree(all: false, bundled, in: &ctx) }
        #expect(two?.code == .usage && two?.message == "2 running apps have the bundle id dev.other")
    }

    @Test func stopForgetsTheRefsAndSaysThereIsNoRunner() async throws {
        defer { worktree.remove() }
        var (service, ctx) = try setup(FakeAccessibility(app: Self.app))
        _ = try await service.tree(all: false, options, in: &ctx)
        let stopped = try await service.stop(device: nil, rebuild: true, in: &ctx)
        #expect(stopped.text.contains("forgot the refs of mac") && stopped.text.contains("no runner to stop on a Mac"))
        // The flag as given, in the JSON; the text says it did nothing and never that the runner will be rebuilt.
        #expect(stopped.rebuild == true && stopped.text.contains("--rebuild does nothing on a Mac") && !stopped.text.contains("will be rebuilt"))
        #expect(!FileManager.default.fileExists(atPath: MacRefStore.file(ctx.paths, device: "mac")))
    }

    /// An app launched hidden may have no window yet; the tree says so and how to get one.
    @Test func aTreeOfAnAppWithNoWindowSaysHowToOpenOne() async throws {
        defer { worktree.remove() }
        var (service, ctx) = try setup(FakeAccessibility(app: FakeApp(windows: [], hidden: true)))
        let report = try await service.tree(all: false, options, in: &ctx)
        #expect(report.tree.elements.isEmpty && report.tree.windows == 0)
        #expect(report.text == "running (hidden)  no windows\n"
            + "next: the app has no window; open one with `xcd open <route>`, or watch it with `xcd launch --show`")
    }

    /// The header replaces the simulator's wherever a tree is printed: `ui tree`, and an action's `--tree`.
    @Test func everyPrintedMacTreeHasTheMacHeaderAndSaysWhenItWasCapped() {
        var tree = TreeResult(bundleId: "dev.x.Mac", state: "foreground", screen: ScreenRect(x: 0, y: 0, w: 900, h: 552), scale: 2,
                              orientation: "none", keyboard: false, elements: UIServiceTests.tree.elements)
        tree.hidden = false
        tree.windowTitle = "Probe"
        tree.windows = 2
        tree.capped = true
        let lines = UIText.tree(tree)
        #expect(lines.first == "running (visible)  window: Probe 900x552 @2x  windows: 2")
        #expect(lines.last == "note: the tree was capped (5000 nodes or depth 40); the rest is not listed")
        var action = UIActionReport(action: "tapped", target: "id:go", element: nil, x: nil, y: nil, ms: 3, restarted: false,
                                    device: "mac", udid: "pid 7", worktree: "w")
        action.tree = tree
        #expect(action.text.contains("\nrunning (visible)  window: Probe 900x552 @2x  windows: 2\n"))
        tree.windowTitle = ""
        tree.windows = 1
        #expect(UIText.tree(tree).first == "running (visible)  window: untitled 900x552 @2x")
    }

    /// The Mac's pasteboard is the person's: the image is refused before the file is even read.
    @Test func anImageForTheMacsPasteboardIsRefused() async throws {
        defer { worktree.remove() }
        var (service, ctx) = try setup(FakeAccessibility(app: Self.app))
        let refused = await #expect(throws: XcdError.self) {
            _ = try await service.setPasteboardImage(file: worktree.root + "/missing.png", device: nil, in: &ctx)
        }
        #expect(refused?.code == .platformUnsupported && refused?.message == "the Mac's pasteboard is the person's; xcd never reads or writes it")
        #expect(refused?.next == "copy on the Mac yourself, or use a simulator device")
    }
}
