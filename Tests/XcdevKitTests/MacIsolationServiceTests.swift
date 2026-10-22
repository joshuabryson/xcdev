import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Which product a Mac device's commands read, and what a launch does first, under each isolation mode. The worktree
/// `FakeWorktree` makes is named "feat".
@Suite struct MacIsolationServiceTests {
    let worktree = FakeWorktree(prefix: "xcd isolation")
    var fake: FakeProcessRunner { worktree.runner }
    let apps = FakeRunningApps()
    static let betaCopy = "/Users/u/App.worktrees/beta/.xcdev/DerivedData/Build/Products/Debug/Mac.app/Contents/MacOS/Mac"

    /// A config whose `mac` device has `isolation` set to this, or no `isolation` key.
    static func yaml(_ isolation: String? = nil) -> String {
        let mac = isolation.map { "mac: { platform: macOS, isolation: \($0) }" } ?? "mac: { platform: macOS }"
        return """
        version: 1
        project: App.xcodeproj
        defaultDevice: mac
        devices:
          iphone: { type: "iPhone 18 Pro" }
          \(mac)
        """
    }

    /// This worktree's build of `dev.x.Mac`, where xcd builds it.
    static func macBuild(_ ctx: WorktreeContext) -> AppProduct {
        AppProduct(path: ctx.paths.derivedData + "/Build/Products/Debug/Mac.app", bundleId: "dev.x.Mac",
                   executableName: "Mac", platform: "macosx")
    }

    /// `macBuild`, recorded as the `mac` device's latest build.
    @discardableResult
    static func recordBuild(_ ctx: WorktreeContext) throws -> AppProduct {
        let built = macBuild(ctx)
        try AppStateStore.save(AppState(builds: ["mac": BuildRecord(scheme: "App", configuration: nil, product: built,
                                                                     finishedAt: Date())]), ctx.paths)
        return built
    }

    /// A built Mac app at `path`: a binary Info.plist (what Xcode writes) with `id`, the executable name `Mac`, and
    /// `extra`; and its executable.
    static func makeApp(at path: String, id: String = "dev.x.Mac", extra: [String: Any] = [:]) throws {
        let plist = extra.merging(["CFBundleIdentifier": id, "CFBundleExecutable": "Mac"]) { $1 }
        try MacBundleTests.makeBundle(at: path, plist: plist, format: .binary, files: ["Contents/MacOS/Mac"])
    }

    /// A signature whose entitlements are the sandbox alone, as a plain sandboxed app's are.
    static func sandboxed(_ id: String = "dev.x.Mac") throws -> MacSigningInfo {
        try MacBundleTests.sandboxed(id)
    }

    /// Isolation that copies the app it makes at `app` (signed as a plain sandboxed app) with the real `ditto` and a
    /// stubbed `codesign`, and sees `apps` running.
    static func copying(_ app: String, on fake: FakeProcessRunner, apps: FakeRunningApps = FakeRunningApps(),
                        extra: [String: Any] = [:]) throws -> MacIsolationService {
        try makeApp(at: app, extra: extra)
        let reader = FakeBundleReader()
        reader.set(try sandboxed(), for: app)
        fake.stub(["codesign"])
        return MacIsolationService(runner: RoutingRunner(fake: fake, realExecutables: ["ditto"]), reader: reader, runningApps: apps)
    }

    /// Isolation that copies nothing and sees nothing running: what a test of something else needs.
    static func quiet(on runner: any ProcessRunning) -> MacIsolationService {
        MacIsolationService(runner: runner, reader: FakeBundleReader(), runningApps: FakeRunningApps())
    }

    @Test func aSharedDeviceKeepsTheBuiltProduct() throws {
        defer { worktree.remove() }
        for yaml in [Self.yaml(), Self.yaml("shared")] {
            let ctx = try worktree.context(yaml)
            #expect(MacIsolationService.mode(of: "mac", in: ctx) == .sharedData)
            #expect(MacIsolationService.product(Self.macBuild(ctx), device: "mac", in: ctx) == Self.macBuild(ctx))
        }
    }

    @Test func aSuffixDeviceMapsToTheCopyIdentity() throws {
        defer { worktree.remove() }
        let ctx = try worktree.context(Self.yaml("suffix"))
        #expect(MacIsolationService.mode(of: "mac", in: ctx) == .suffix)
        #expect(MacIsolationService.product(Self.macBuild(ctx), device: "mac", in: ctx)
                == AppProduct(path: worktree.root + "/.xcdev/mac/Mac.app", bundleId: "dev.x.Mac.xcd-feat",
                              executableName: "Mac", platform: "macosx"))
    }

    @Test func aSimulatorProductIsNeverMapped() async throws {
        defer { worktree.remove() }
        let ctx = try worktree.context(Self.yaml("suffix"))
        let phone = AppProduct(path: "/dd/App.app", bundleId: "dev.x.App", executableName: "App", platform: "iphonesimulator")
        #expect(MacIsolationService.product(phone, device: "iphone", in: ctx) == phone)
        #expect(MacIsolationService.product(phone, device: "mac", in: ctx) == phone)
        #expect(MacIsolationService.mode(of: "iphone", in: ctx) == .sharedData && MacIsolationService.mode(of: "nope", in: ctx) == .sharedData)
        let service = MacIsolationService(runner: fake, reader: FakeBundleReader(), runningApps: apps)
        #expect(try await service.prepareLaunch(built: phone, device: "mac", in: ctx) == phone)
        #expect(apps.queries.isEmpty && fake.calls.isEmpty)
    }

    @Test func theNoteNamesTheIsolationUnderSuffixAndSharedDataUnderShared() throws {
        defer { worktree.remove() }
        let suffix = try worktree.context(Self.yaml("suffix"))
        #expect(MacIsolationService.note(for: Self.macBuild(suffix), device: "mac", in: suffix) == "isolation: dev.x.Mac.xcd-feat")
        let shared = try worktree.context(Self.yaml())
        #expect(MacIsolationService.note(for: Self.macBuild(shared), device: "mac", in: shared) == RunReport.sharedData(of: "dev.x.Mac"))
    }

    @Test func prepareLaunchRefreshesTheCopyUnderSuffix() async throws {
        defer { worktree.remove() }
        let ctx = try worktree.context(Self.yaml("suffix"))
        let built = Self.macBuild(ctx)
        let service = try Self.copying(built.path, on: fake, apps: apps)
        let product = try await service.prepareLaunch(built: built, device: "mac", in: ctx)
        #expect(product == MacIsolationService.product(built, device: "mac", in: ctx))
        let info = try Data(contentsOf: URL(fileURLWithPath: product.path + "/Contents/Info.plist"))
        let id = (try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any])?["CFBundleIdentifier"] as? String
        #expect(id == "dev.x.Mac.xcd-feat")
        // The copy is signed beside its final path, at `<copy>.partial`, and only then moved into place.
        #expect(fake.calls.filter { $0.argv[0] == "codesign" }.map { $0.arguments.last } == [product.path + ".partial"])
        _ = try await service.prepareLaunch(built: built, device: "mac", in: ctx)       // nothing rebuilt: the copy stands
        #expect(fake.calls.filter { $0.argv[0] == "codesign" }.count == 1)
    }

    @Test func prepareLaunchRefusesAppInUseUnderShared() async throws {
        defer { worktree.remove() }
        let ctx = try worktree.context(Self.yaml())
        let built = Self.macBuild(ctx)
        let service = MacIsolationService(runner: fake, reader: FakeBundleReader(), runningApps: apps)
        apps.set([MacRunningCopy(pid: 300, executablePath: Self.betaCopy)], for: "dev.x.Mac")
        let error = await #expect(throws: XcdError.self) { try await service.prepareLaunch(built: built, device: "mac", in: ctx) }
        #expect(error?.code == .appInUse && error?.message.contains("from the worktree at /Users/u/App.worktrees/beta (pid 300)") == true)
        #expect(apps.queries == ["dev.x.Mac"] && fake.calls.isEmpty)
        apps.set([], for: "dev.x.Mac")
        #expect(try await service.prepareLaunch(built: built, device: "mac", in: ctx) == built)
    }

    /// Each worktree's copy has its own identifier, so another worktree's copy running is no reason to refuse.
    @Test func prepareLaunchSkipsTheGuardUnderSuffix() async throws {
        defer { worktree.remove() }
        let ctx = try worktree.context(Self.yaml("suffix"))
        let built = Self.macBuild(ctx)
        let service = try Self.copying(built.path, on: fake, apps: apps)
        apps.set([MacRunningCopy(pid: 300, executablePath: Self.betaCopy)], for: "dev.x.Mac")
        let product = try await service.prepareLaunch(built: built, device: "mac", in: ctx)
        #expect(product.bundleId == "dev.x.Mac.xcd-feat" && apps.queries.isEmpty)
    }
}
