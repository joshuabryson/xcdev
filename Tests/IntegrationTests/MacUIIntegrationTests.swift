import AppKit
import AVFoundation
import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"

/// A real Mac app, driven hidden: the fixture app, built with `swiftc` and recorded as the Mac
/// device's build, so every step goes through the real Accessibility API and ScreenCaptureKit. Needs an unlocked screen,
/// the Accessibility and Screen Recording grants for the app that runs `swift test`, and `.build/debug/xcd` (a recording
/// runs it). Run it hands-off: before and after every step the frontmost app and the pointer are read, and they must not
/// change, so a person who moves the pointer or switches apps meanwhile fails the run. Never run with the other
/// integration suites at once.
@Suite(.enabled(if: enabled, "set XCD_INTEGRATION=1 to run (needs the Accessibility and Screen Recording grants)"), .serialized)
struct MacUIIntegrationTests {
    let runner = SystemProcessRunner()
    let ui = UIOptions(device: "mac", bundle: nil, system: false, role: nil, index: nil, timeout: .seconds(5))
    /// The xcd a recording runs as `xcd _record-window`: under `swift test` the default is the test host.
    let xcd = repoRoot + "/.build/debug/xcd"
    static let bundleId = "dev.xcdev.MacProbeApp"
    /// A launch that starts with the fixture's one window: the windows an earlier run left are not restored. Without
    /// it, a copy killed with two windows comes back with two, and every identifier matches twice. macOS 27 keeps that
    /// state in `~/Library/Daemon Containers/<uuid>/Data/Library/Saved Application State/<uuid>.savedState`, a folder
    /// only its `ApplicationMapping.plist` names, not in `~/Library/Saved Application State` (measured 2026-10-20).
    let launch = LaunchOptions(arguments: ["-ApplePersistenceIgnoreState", "YES"])

    func project() throws -> TempProject {
        try TempProject.make(config: """
        version: 1
        project: SampleApp.xcodeproj
        schemes: { app: SampleApp, test: SampleApp }
        defaultDevice: mac
        devices:
          mac: { platform: macOS }
        deeplinks:
          routes:
            count:
              description: "Set the probe's counter"
              url: "macprobe://set?count={n}"
              expect: "label:count: {n}"
              params:
                n: { description: "The new count" }
        """, name: "Mac App \(UUID().uuidString.prefix(6))", fixture: repoRoot + "/Fixtures/SampleApp", parent: testsHome)
    }

    /// Builds the fixture into the worktree's DerivedData and records it as the Mac device's build.
    func install(in ctx: WorktreeContext) async throws -> AppProduct {
        let out = ctx.paths.derivedData + "/Build/Products/Debug"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try await runner.runChecked(Invocation("/bin/sh", [repoRoot + "/Tests/Fixtures/MacProbeApp/build.sh", out], timeout: .seconds(300)))
        let product = AppProduct(path: out + "/MacProbeApp.app", bundleId: Self.bundleId, executableName: "MacProbeApp", platform: "macosx")
        var state = AppState()
        state.builds["mac"] = BuildRecord(scheme: "SampleApp", configuration: "Debug", product: product, finishedAt: Date())
        try AppStateStore.save(state, ctx.paths)
        return product
    }

    /// Runs `body` on a new project with the fixture installed, then always stops a recording that is still going and
    /// every copy of the fixture at this project's path, and deletes the project. No simulator is involved, so unlike
    /// `withCleanup` it asks simctl for nothing.
    func withFixture(_ body: (inout WorktreeContext, Services, AppProduct) async throws -> Void) async throws {
        let project = try project()
        defer { project.remove() }
        var svc = services(project)
        svc.xcdExecutable = xcd
        var ctx = try await svc.open(worktree: nil)
        let product = try await install(in: ctx)
        var failure: (any Error)?
        do { try await body(&ctx, svc, product) } catch { failure = error }
        _ = try? await svc.media.stopRecording(device: "mac", in: ctx)
        _ = try? await MacAppHost(runner: runner).terminate(product)
        if let failure { throw failure }
    }

    /// What the run needs, checked before anything starts: each missing one is one issue that says what to do.
    func ready() -> Bool {
        let api = SystemAccessibility()
        let host = MacHostApp.live()
        let lock = MacScreenLock.refusal
        let missing = [
            MacScreenLock.isLocked() ? "\(lock.message); \(lock.next ?? "")" : nil,
            api.isTrusted ? nil : "\(host) has no Accessibility permission; \(MacPermissions.accessibilityNext(host))",
            api.screenCaptureAllowed ? nil : "\(host) has no Screen Recording permission; \(MacPermissions.screenRecordingNext(host))",
            FileManager.default.isExecutableFile(atPath: xcd) ? nil : "\(xcd) is missing, and a recording runs it: run `swift build` in \(repoRoot)",
        ].compactMap { $0 }
        for problem in missing { Issue.record(Comment(rawValue: problem)) }
        return missing.isEmpty
    }

    @Test(.timeLimit(.minutes(10))) func drivesAHiddenMacAppWithoutTouchingTheDesk() async throws {
        guard ready() else { return }
        try await withFixture { ctx, svc, product in
            let start = try await desk()
            let ref = try await launchesHiddenAndReads(&ctx, svc)
            try await tapsAndTypes(ref, &ctx, svc)
            try await scrollsAndTapsTheOldRef(ref, &ctx, svc)
            try await pressesTheMenuBar(&ctx, svc)
            try await capturesTheWindow(&ctx, svc)
            try await opensALinkHidden(&ctx, svc)
            try await readsTheTreeRightAfterALink(product, &ctx, svc)
            try await refusesWhatAMacCannotDo(&ctx, svc)
            try await relaunchesAndStops(ref, &ctx, svc)
            try await untouched(start, "the whole run")
        }
    }

    // MARK: The steps

    /// The launch puts no window on screen; the tree has the identifiers and says the app is hidden. Returns the
    /// ref of the Increment button.
    func launchesHiddenAndReads(_ ctx: inout WorktreeContext, _ svc: Services) async throws -> String {
        let launched = try await step("xcd launch") { try await svc.apps.launch(device: "mac", options: launch, in: &ctx) }
        try #require(launched.status == .running, "\(launched.text)")
        let report = try await step("xcd ui tree") { try await svc.ui.tree(all: false, ui, in: &ctx) }
        let tree = report.tree
        #expect(tree.hidden == true && report.text.hasPrefix("running (hidden)  window: Probe "), "\(report.text.prefix(400))")
        #expect(tree.windows == 1, "a fresh launch with no saved state has \(String(describing: tree.windows)) windows")
        for id in ["count", "increment", "name", "name-mirror", "submits", "last-row", "appkit-button", "row-1"] {
            #expect(tree.elements.contains { $0.identifier == id }, "no \(id) in the tree:\n\(report.text.prefix(2000))")
        }
        print("MacUI measured: launch header `\(report.text.prefix { $0 != "\n" })`, \(tree.elements.count) elements")
        return try #require(tree.elements.first { $0.identifier == "increment" }?.ref)
    }

    /// A tap by the tree's ref, then typing with `--submit`, then text a key code cannot carry with `--clear` and
    /// `--submit`.
    func tapsAndTypes(_ ref: String, _ ctx: inout WorktreeContext, _ svc: Services) async throws {
        _ = try await step("xcd ui tap \(ref)") { try await svc.ui.tap(ref, ui, in: &ctx) }
        try await label("count: 1", &ctx, svc)
        let typed = try await step("xcd ui type hello --submit") {
            try await svc.ui.type("hello", TypeOptions(into: "id:name", clear: false, submit: true), ui, in: &ctx)
        }
        #expect(typed.detail == "by keyboard, then Return", "\(typed.text)")
        try await label("name: hello", &ctx, svc)
        try await label("submits: 1", &ctx, svc)
        _ = try await step("xcd ui type 'é😀 ok' --clear --submit") {
            try await svc.ui.type("é😀 ok", TypeOptions(into: "id:name", clear: true, submit: true), ui, in: &ctx)
        }
        try await label("name: é😀 ok", &ctx, svc)
        try await label("submits: 2", &ctx, svc)
        let field = try await step("xcd ui tree") { try await svc.ui.tree(all: false, ui, in: &ctx) }.tree.elements.first { $0.identifier == "name" }
        #expect(field?.value == "é😀 ok", "the field holds \(String(describing: field?.value))")
    }

    /// A swipe scrolls the list one page, and the ref from the first tree still taps the button.
    func scrollsAndTapsTheOldRef(_ ref: String, _ ctx: inout WorktreeContext, _ svc: Services) async throws {
        let before = try await step("xcd ui tree") { try await svc.ui.tree(all: false, ui, in: &ctx) }.tree
        _ = try await step("xcd ui swipe up --on id:row-1") {
            try await svc.ui.swipe(SwipeOptions(direction: "up", on: "id:row-1", from: nil, to: nil), ui, in: &ctx)
        }
        let after = try await step("xcd ui tree") { try await svc.ui.tree(all: false, ui, in: &ctx) }.tree
        #expect((rows(after).max() ?? 0) > (rows(before).max() ?? 0), "the list did not scroll: rows \(rows(before)) then \(rows(after))")
        print("MacUI measured: rows on screen \(rows(before)) then \(rows(after)); row-1 at \(String(describing: frame("row-1", before))) then \(String(describing: frame("row-1", after)))")
        _ = try await step("xcd ui tap \(ref) again") { try await svc.ui.tap(ref, ui, in: &ctx) }
        try await label("count: 2", &ctx, svc)
    }

    /// `xcd ui menu` lists the menu bar as paths and presses one.
    func pressesTheMenuBar(_ ctx: inout WorktreeContext, _ svc: Services) async throws {
        let menu = try await step("xcd ui menu") { try await svc.ui.menu(nil, ui, in: &ctx) }
        #expect(menu.items?.contains { $0.path == "Probe > Bump by ten" && $0.enabled } == true, "\(menu.text.prefix(2000))")
        let pressed = try await step("xcd ui menu 'Probe > Bump by ten'") { try await svc.ui.menu("Probe > Bump by ten", ui, in: &ctx) }
        #expect(pressed.pressed == "Probe > Bump by ten")
        _ = try await step("xcd ui wait --gone 'label:count: 2'") { try await svc.ui.wait("label:count: 2", gone: true, ui, in: &ctx) }
        try await label("count: 12", &ctx, svc)
        print("MacUI measured: the menu bar lists \(menu.items?.count ?? 0) paths")
    }

    /// The screenshot is the main window at the screen's scale and not blank; the recording is a playable MP4 of
    /// stills, about five a second. Both before any link: after one, the capture can pick the link's empty twin window.
    func capturesTheWindow(_ ctx: inout WorktreeContext, _ svc: Services) async throws {
        let tree = try await step("xcd ui tree") { try await svc.ui.tree(all: false, ui, in: &ctx) }.tree
        let shot = try await step("xcd ui screenshot") { try await svc.media.screenshot(device: "mac", out: nil, in: &ctx) }
        let width = Int((tree.screen.w * tree.scale).rounded()), height = Int((tree.screen.h * tree.scale).rounded())
        #expect(shot.udid == nil && shot.scale == tree.scale && shot.width == width && shot.height == height,
                "\(shot.text) for a \(tree.screen.w)x\(tree.screen.h) window at \(tree.scale)x")
        #expect(try distinctColors(in: shot.path) > 2, "the screenshot \(shot.path) is blank")

        let started = try await step("xcd ui record start") { try await svc.media.startRecording(device: "mac", out: nil, in: &ctx) }
        #expect(started.action == .started && started.udid == nil, "\(started.text)")
        try await Task.sleep(for: .seconds(3))
        let stopped = try await step("xcd ui record stop") { try await svc.media.stopRecording(device: "mac", in: ctx) }
        #expect(stopped.action == .stopped && stopped.outcome == .stopped && stopped.udid == nil && (stopped.bytes ?? 0) > 1000, "\(stopped.text)")
        let clip = try await clip(at: try #require(stopped.path))
        #expect(clip.playable && clip.frames >= 8 && clip.seconds > 1.5 && clip.seconds < 6, "\(clip)")
        #expect(abs(clip.width - (shot.width ?? 0)) <= 2 && abs(clip.height - (shot.height ?? 0)) <= 2, "\(clip) against \(shot.text)")
        print("MacUI measured: screenshot \(shot.width ?? 0)x\(shot.height ?? 0) @\(shot.scale ?? 0)x; clip \(clip)")
    }

    /// `xcd open` sends the route's link to the hidden copy, and its arrival check finds `count: 7`; the app stays hidden.
    func opensALinkHidden(_ ctx: inout WorktreeContext, _ svc: Services) async throws {
        let opened = try await step("xcd open count n=7") {
            try await svc.routes.open(.route(name: "count", values: ["n": "7"]), OpenOptions(), in: &ctx)
        }
        #expect(opened.app?.state == .running && opened.linkSent == true && opened.failure == nil, "\(opened.text)")
        #expect(opened.check?.outcome == .appeared && opened.check?.target == "label:count: 7", "\(opened.text)")
        let seen = try await step("the arrival look") { try await svc.ui.look(for: "label:count: 7", timeout: .seconds(5), device: "mac", in: &ctx) }
        if case .missing = seen { Issue.record("the link's count did not arrive: \(seen)") }
        let report = try await step("xcd ui tree") { try await svc.ui.tree(all: false, ui, in: &ctx) }
        #expect(report.tree.hidden == true, "the link unhid the app")
        // A link opens an empty twin window only beside restored windows (measured 2026-10-20), which these launches have
        // none of; whatever the count, the header says it when there is more than one.
        #expect(report.text.contains("  windows: ") == ((report.tree.windows ?? 0) > 1), "\(report.text.prefix(300))")
        #expect(report.tree.elements.contains { $0.identifier == "increment" }, "the tree after the link lost the controls")
        print("MacUI measured: after the link `\(report.text.prefix { $0 != "\n" })`; open: \(opened.text.replacingOccurrences(of: "\n", with: " | "))")
    }

    /// The app rebuilds its content when a link arrives, and the first tree read after one used to meet an element that
    /// had gone (5 times out of 5, measured 2026-10-20). Each of three links is followed at once by a tree, which must
    /// read, and then by the count the link set.
    func readsTheTreeRightAfterALink(_ product: AppProduct, _ ctx: inout WorktreeContext, _ svc: Services) async throws {
        for count in 8...10 {
            let report = try await step("a link to count \(count), then at once xcd ui tree") {
                try await MacAppHost(runner: runner).open("macprobe://set?count=\(count)", in: product)
                return try await svc.ui.tree(all: false, ui, in: &ctx)
            }
            #expect(report.tree.hidden == true && report.tree.elements.contains { $0.identifier == "increment" }, "\(report.text.prefix(400))")
            try await label("count: \(count)", &ctx, svc)
        }
    }

    /// What a Mac cannot do is refused with `platform_unsupported`, and nothing happens on the desk.
    func refusesWhatAMacCannotDo(_ ctx: inout WorktreeContext, _ svc: Services) async throws {
        var system = ui
        system.system = true
        try await refused("xcd ui tap @10,10") { _ = try await svc.ui.tap("@10,10", ui, in: &ctx) }
        // It would open the context menu on the person's screen (measured: a pop-up menu window, there until pressed).
        let press = try await refused("xcd ui long-press id:row-3") { _ = try await svc.ui.longPress("id:row-3", duration: .seconds(1), ui, in: &ctx) }
        #expect(press?.message == "a long-press opens the element's context menu on the person's screen (a visible menu window until one of its items is pressed)")
        #expect(press?.next == "use `xcd ui menu \"<Menu> > <Item>\"` for the app's commands; a flag that allows a visible context menu is a follow-up")
        try await refused("xcd ui swipe --from --to") {
            _ = try await svc.ui.swipe(SwipeOptions(direction: nil, on: nil, from: "10,10", to: "10,200"), ui, in: &ctx)
        }
        try await refused("xcd ui button home") { _ = try await svc.ui.button("home", ui, in: &ctx) }
        try await refused("xcd ui rotate landscape-left") { _ = try await svc.ui.rotate("landscape-left", ui, in: &ctx) }
        try await refused("xcd ui tree --system") { _ = try await svc.ui.tree(all: false, system, in: &ctx) }
        // What every `sim` state command does first.
        let boot = try await refused("xcd sim boot") { _ = try await svc.provisioner.boot("mac", in: &ctx) }
        #expect(boot?.next?.contains("--show") == true, "\(String(describing: boot))")
    }

    /// A relaunch makes the old ref stale; `xcd ui stop` forgets the refs, as there is no runner to stop.
    func relaunchesAndStops(_ ref: String, _ ctx: inout WorktreeContext, _ svc: Services) async throws {
        let relaunched = try await step("xcd launch again") { try await svc.apps.launch(device: "mac", options: launch, in: &ctx) }
        try #require(relaunched.status == .running, "\(relaunched.text)")
        let stale = try await step("xcd ui tap \(ref) after the relaunch") {
            await #expect(throws: XcdError.self) { _ = try await svc.ui.tap(ref, ui, in: &ctx) }
        }
        #expect(stale?.code == .staleRef, "\(String(describing: stale))")
        let tree = try await step("xcd ui tree") { try await svc.ui.tree(all: false, ui, in: &ctx) }
        #expect(tree.tree.hidden == true && tree.tree.windows == 1 && tree.tree.elements.contains { $0.identifier == "increment" }, "\(tree.text.prefix(400))")
        let stopped = try await step("xcd ui stop") { try await svc.ui.stop(device: "mac", rebuild: false, in: &ctx) }
        #expect(stopped.stopped == ["forgot the refs of mac; there is no runner to stop on a Mac"], "\(stopped.text)")
        #expect(!FileManager.default.fileExists(atPath: MacRefStore.file(ctx.paths, device: "mac")))
        let ended = try await step("xcd terminate") { try await svc.apps.terminate(device: "mac", in: &ctx) }
        print("MacUI measured: after the relaunch `\(tree.text.prefix { $0 != "\n" })`; terminate: \(ended.text)")
    }

    // MARK: The desk

    /// Everything a step must leave alone.
    struct Desk { let front: String; let pointer: CGPoint }

    func frontmost() async throws -> String {
        let front = try await runner.run(Invocation("/usr/bin/lsappinfo", ["front"])).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = try await runner.run(Invocation("/usr/bin/lsappinfo", ["info", "-only", "name", front])).stdoutString
        return String(info.prefix { $0 != "\n" })
    }
    func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
    func desk() async throws -> Desk { Desk(front: try await frontmost(), pointer: pointer()) }

    /// The windows of any copy of the fixture that are on screen, as their layer and bounds: a hidden app has none.
    func windowsOnScreen() -> [String] {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).map(\.processIdentifier))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber).map { pids.contains($0.int32Value) } == true }.map { window in
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let rect = ["X", "Y", "Width", "Height"].map { "\(bounds[$0] ?? "?")" }
            return "layer \(window[kCGWindowLayer as String] ?? "?") at \(rect[0]),\(rect[1]) \(rect[2])x\(rect[3])"
        }
    }

    func untouched(_ before: Desk, _ step: String) async throws {
        let after = try await desk()
        #expect(after.front == before.front, "\(step) changed the frontmost app from \(before.front) to \(after.front)")
        #expect(after.pointer == before.pointer, "\(step) moved the pointer from \(before.pointer) to \(after.pointer)")
        let shown = windowsOnScreen()
        #expect(shown.isEmpty, "\(step) left windows of the app on screen: \(shown)")
    }

    /// One step, with the desk read before and after it.
    func step<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        let before = try await desk()
        let result = try await body()
        try await untouched(before, name)
        return result
    }

    /// A step that must be refused with `platform_unsupported`; returns the error.
    @discardableResult
    func refused(_ name: String, _ body: () async throws -> Void) async throws -> XcdError? {
        try await step(name) {
            let error = await #expect(throws: XcdError.self, "\(name) was not refused") { try await body() }
            #expect(error?.code == .platformUnsupported, "\(name): \(String(describing: error))")
            return error
        }
    }

    func label(_ text: String, _ ctx: inout WorktreeContext, _ svc: Services) async throws {
        _ = try await step("xcd ui wait 'label:\(text)'") { try await svc.ui.wait("label:\(text)", gone: false, ui, in: &ctx) }
    }

    // MARK: Reading what came out

    /// The numbers of the list's rows in the default tree, which leaves out what is off screen.
    func rows(_ tree: TreeResult) -> [Int] {
        tree.elements.compactMap { $0.identifier.hasPrefix("row-") ? Int($0.identifier.dropFirst(4)) : nil }.sorted()
    }

    func frame(_ identifier: String, _ tree: TreeResult) -> ScreenRect? { tree.elements.first { $0.identifier == identifier }?.frame }

    /// How many different colours a 20 by 20 grid of the image's pixels has: a blank capture has one.
    func distinctColors(in path: String) throws -> Int {
        let image = try #require(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))), "\(path) is not an image")
        var colors = Set<String>()
        for x in stride(from: 0, to: image.pixelsWide, by: max(1, image.pixelsWide / 20)) {
            for y in stride(from: 0, to: image.pixelsHigh, by: max(1, image.pixelsHigh / 20)) {
                colors.insert(image.colorAt(x: x, y: y)?.description ?? "none")
            }
        }
        return colors.count
    }

    /// What AVFoundation reads from a recording.
    struct Clip: CustomStringConvertible {
        let frames: Int
        let seconds: Double
        let width: Int
        let height: Int
        let playable: Bool
        var description: String { "\(frames) frames, \(String(format: "%.2f", seconds)) s, \(width)x\(height), playable: \(playable)" }
    }

    func clip(at path: String) async throws -> Clip {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first, "\(path) has no video track")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading(), "\(path) cannot be read: \(String(describing: reader.error))")
        var frames = 0
        while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) > 0 ? 1 : 0 }
        let size = try await track.load(.naturalSize)
        return Clip(frames: frames, seconds: try await asset.load(.duration).seconds, width: Int(size.width.rounded()),
                    height: Int(size.height.rounded()), playable: try await asset.load(.isPlayable))
    }
}
