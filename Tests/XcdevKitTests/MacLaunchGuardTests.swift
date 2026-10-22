import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Which running copy of a Mac app blocks a launch under `isolation: shared`.
@Suite struct MacLaunchGuardTests {
    static let beta = "/Users/u/P.worktrees/beta"
    static let betaApp = beta + "/.xcdev/DerivedData/Build/Products/Debug/App.app"

    /// A running copy of the app bundle at `app`, as `NSRunningApplication` lists it: by its executable.
    static func running(_ pid: Int32, _ app: String) -> MacRunningCopy {
        MacRunningCopy(pid: pid, executablePath: app + "/Contents/MacOS/App")
    }

    @Test func aCopyFromAnotherWorktreesXcdevFolderBlocksAndNamesIt() {
        let found = MacLaunchGuard.blocker(among: [Self.running(41, Self.betaApp)], worktreeRoot: "/Users/u/P.worktrees/alpha")
        #expect(found == MacLaunchBlocker(worktreeRoot: Self.beta, pid: 41))
    }

    /// This worktree's build, and its `isolation: suffix` copy left running from before a config change, are its own:
    /// `begin` stops the first by path, as today.
    @Test func theWorktreesOwnCopyNeverBlocks() {
        let own = [Self.running(41, Self.betaApp), Self.running(42, Self.beta + "/.xcdev/mac/App.app")]
        #expect(MacLaunchGuard.blocker(among: own, worktreeRoot: Self.beta) == nil)
        #expect(MacLaunchGuard.blocker(among: own, worktreeRoot: Self.beta + "/") == nil)
    }

    /// The user's installed copy and a build from Xcode's own DerivedData have no `.xcdev/` in their path.
    @Test func aCopyOutsideAnyXcdevFolderNeverBlocks() {
        let users = [Self.running(10, "/Applications/App.app"),
                     Self.running(11, "/Users/u/Library/Developer/Xcode/DerivedData/App-abc/Build/Products/Debug/App.app")]
        #expect(MacLaunchGuard.blocker(among: users, worktreeRoot: "/Users/u/P") == nil)
    }

    @Test func theLowestPidWinsWhenSeveralBlock() {
        let gamma = "/Users/u/P.worktrees/gamma"
        let copies = [Self.running(90, Self.betaApp), Self.running(5, "/Applications/App.app"),
                      Self.running(12, gamma + "/.xcdev/DerivedData/Build/Products/Debug/App.app")]
        #expect(MacLaunchGuard.blocker(among: copies, worktreeRoot: "/Users/u/P") == MacLaunchBlocker(worktreeRoot: gamma, pid: 12))
    }

    @Test func aCopyWithNoPathNeverBlocks() {
        #expect(MacLaunchGuard.blocker(among: [MacRunningCopy(pid: 3, executablePath: nil)], worktreeRoot: "/Users/u/P") == nil)
    }

    @Test func theErrorIsAppInUseExitThreeWithTheTerminateNext() throws {
        let worktree = FakeWorktree(prefix: "xcd guard")
        defer { worktree.remove() }
        let ctx = try worktree.context("""
        version: 1
        project: App.xcodeproj
        defaultDevice: mac
        devices:
          mac: { platform: macOS }
        """)
        let product = AppProduct(path: ctx.paths.derivedData + "/Build/Products/Debug/App.app", bundleId: "dev.x.App",
                                 executableName: "App", platform: "macosx")
        let apps = FakeRunningApps()
        apps.set([Self.running(41, Self.betaApp)], for: "dev.x.App")
        let error = #expect(throws: XcdError.self) { try MacLaunchGuard.check(product: product, device: "mac", in: ctx, apps: apps) }
        #expect(error?.code == .appInUse && ErrorCode.appInUse.exitCode == 3)
        #expect(error?.message == "dev.x.App is already running from the worktree at /Users/u/P.worktrees/beta (pid 41); "
                    + "under isolation: shared both copies would share its data")
        #expect(error?.next == "ask the user, or run `xcd terminate --device mac` in that worktree; "
                    + "`isolation: suffix` in .xcdev.yml gives each worktree its own copy")
        #expect(apps.queries == ["dev.x.App"])
        apps.set([Self.running(41, product.path)], for: "dev.x.App")        // this worktree's own copy
        #expect(throws: Never.self) { try MacLaunchGuard.check(product: product, device: "mac", in: ctx, apps: apps) }
    }

    /// The same worktree reached through a link is still the same worktree.
    @Test func canonicalPathsCompareEqualThroughSymlinks() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("xcd guard \(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base + "/real/.xcdev", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: base + "/other", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: base + "/link", withDestinationPath: base + "/real")
        let viaLink = Self.running(7, base + "/link/.xcdev/DerivedData/Build/Products/Debug/App.app")
        #expect(MacLaunchGuard.blocker(among: [viaLink], worktreeRoot: base + "/real") == nil)
        #expect(MacLaunchGuard.blocker(among: [viaLink], worktreeRoot: base + "/other") == MacLaunchBlocker(worktreeRoot: base + "/link", pid: 7))
    }
}
