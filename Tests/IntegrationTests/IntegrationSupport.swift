import AppKit
import CoreGraphics
import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
/// Simulators can't write app output under $TMPDIR, so these projects live here instead.
let testsHome = NSHomeDirectory() + "/Library/Caches/xcdev-tests"

/// Live services for `project`, with its own XCDEV_HOME so the real registry is never touched. Its xcd is the built one,
/// not the test host, so a clone it boots gets a real idle watchdog (`xcd _watch-device`): run `swift build` first.
/// A crash report is waited for two minutes rather than xcd's ten seconds: on GitHub's runners one took 46 s to appear.
func services(_ project: TempProject) -> Services {
    var svc = Services(runner: SystemProcessRunner(), globalPaths: GlobalPaths(base: project.home), currentDirectory: project.root,
                       environment: [:])
    svc.xcdExecutable = repoRoot + "/.build/debug/xcd"
    svc.crashWatcher = CrashWatcher(probe: SystemProcessProbe(), locator: CrashReportLocator(), reportWait: .seconds(120))
    return svc
}

/// Runs `body`, then always (even when it throws) deletes every simulator clone of this project and the project.
/// Clones are found by name (`xcd · <project> · …`), so ones a failed step never recorded in state go too.
func withCleanup(_ project: TempProject, _ body: (Services) async throws -> Void) async throws {
    let svc = services(project)
    var failure: (any Error)?
    do { try await body(svc) } catch { failure = error }
    let simctl = SimctlClient(runner: svc.runner, developerDir: nil)
    let prefix = SimNaming.clonePrefix + URL(fileURLWithPath: project.root).lastPathComponent + " · "
    if let catalog = try? await simctl.catalog() {
        for device in catalog.devices where device.name.hasPrefix(prefix) {
            _ = try? await simctl.shutdown(udid: device.udid)
            try? await simctl.delete(udid: device.udid)
        }
    }
    project.remove()
    if let failure { throw failure }
}

/// The first iPhone type an installed iOS runtime supports.
func firstIPhoneType(_ runner: any ProcessRunning) async throws -> SimDeviceType {
    let catalog = try await SimctlClient(runner: runner, developerDir: nil).catalog()
    return try #require(catalog.deviceTypes.first { type in
        type.productFamily == "iPhone" && catalog.runtimes.contains { $0.isAvailable && $0.platform == "iOS" && $0.supports(type) }
    }, "no iPhone simulator runtime installed")
}

// MARK: The Mac fixture app

/// The bundle id of `Tests/Fixtures/MacProbeApp`.
let macProbeBundleId = "dev.xcdev.MacProbeApp"

/// Builds `Tests/Fixtures/MacProbeApp` with `swiftc` into `folder`, signed ad hoc, with the App Sandbox entitlement when
/// `sandboxed`; returns the app's path.
func buildMacProbe(into folder: String, sandboxed: Bool, _ runner: any ProcessRunning) async throws -> String {
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let arguments = [repoRoot + "/Tests/Fixtures/MacProbeApp/build.sh", folder] + (sandboxed ? ["--sandbox"] : [])
    try await runner.runChecked(Invocation("/bin/sh", arguments, timeout: .seconds(300)))
    return folder + "/MacProbeApp.app"
}

/// Puts the fixture app into the worktree's DerivedData and records it as the Mac device's build: copied there with
/// `ditto` from `built`, or built there with `swiftc` when `built` is nil.
func installMacProbe(in ctx: WorktreeContext, from built: String? = nil, _ runner: any ProcessRunning) async throws -> AppProduct {
    let out = ctx.paths.derivedData + "/Build/Products/Debug"
    if let built {
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try await runner.runChecked(Invocation("/usr/bin/ditto", [built, out + "/MacProbeApp.app"]))
    } else {
        _ = try await buildMacProbe(into: out, sandboxed: false, runner)
    }
    let product = AppProduct(path: out + "/MacProbeApp.app", bundleId: macProbeBundleId, executableName: "MacProbeApp", platform: "macosx")
    var state = AppState()
    state.builds["mac"] = BuildRecord(scheme: "SampleApp", configuration: "Debug", product: product, finishedAt: Date())
    try AppStateStore.save(state, ctx.paths)
    return product
}

// MARK: A hands-off run on the Mac's desk

/// What a hands-off step must leave alone: the frontmost app and the pointer.
struct Desk { let front: String; let pointer: CGPoint }

/// The frontmost app's name, as `lsappinfo` gives it.
func frontmost(_ runner: any ProcessRunning) async throws -> String {
    let front = try await runner.run(Invocation("/usr/bin/lsappinfo", ["front"])).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    let info = try await runner.run(Invocation("/usr/bin/lsappinfo", ["info", "-only", "name", front])).stdoutString
    return String(info.prefix { $0 != "\n" })
}

func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

/// The desk now.
func desk(_ runner: any ProcessRunning) async throws -> Desk { Desk(front: try await frontmost(runner), pointer: pointer()) }

/// The on-screen windows of every running app with one of `bundleIds`, as their pid, layer, and bounds: a hidden app
/// has none.
func windowsOnScreen(of bundleIds: [String]) -> [String] {
    let pids = Set(bundleIds.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }.map(\.processIdentifier))
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber).map { pids.contains($0.int32Value) } == true }.map { window in
        let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let rect = ["X", "Y", "Width", "Height"].map { "\(bounds[$0] ?? "?")" }
        return "pid \(window[kCGWindowOwnerPID as String] ?? "?") layer \(window[kCGWindowLayer as String] ?? "?") "
            + "at \(rect[0]),\(rect[1]) \(rect[2])x\(rect[3])"
    }
}

/// A suite run hands-off: before and after each step it reads the desk, and a step must leave the frontmost app and the
/// pointer as they were and put no window of the suite's apps on screen.
protocol HandsOffSuite {
    var runner: SystemProcessRunner { get }
    /// The bundle ids of the apps the suite runs, whose windows must stay off screen.
    var watchedBundleIds: [String] { get }
}

extension HandsOffSuite {
    func untouched(_ before: Desk, _ step: String) async throws {
        let after = try await desk(runner)
        #expect(after.front == before.front, "\(step) changed the frontmost app from \(before.front) to \(after.front)")
        #expect(after.pointer == before.pointer, "\(step) moved the pointer from \(before.pointer) to \(after.pointer)")
        let shown = windowsOnScreen(of: watchedBundleIds)
        #expect(shown.isEmpty, "\(step) left windows of the app on screen: \(shown)")
    }

    /// One step, with the desk read before and after it.
    func step<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        let before = try await desk(runner)
        let result = try await body()
        try await untouched(before, name)
        return result
    }
}
