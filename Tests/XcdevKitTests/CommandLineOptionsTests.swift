import Foundation
import Testing
@testable import XcdevKit

@Suite struct CommandLineOptionsTests {
    @Test func durationOptions() throws {
        #expect(try DurationText.option(nil, flag: "--timeout") == nil)
        #expect(try DurationText.option("45m", flag: "--timeout") == .seconds(2700))
        let error = #expect(throws: XcdError.self) { try DurationText.option("soon", flag: "--timeout") }
        #expect(error?.code == .usage)
        #expect(error?.message == "--timeout soon is not a duration")
        #expect(error?.next == "use a duration like 30s, 5m, or 1h")
    }

    @Test func logOptionsDefaultsAndFollow() throws {
        let plain = try LogOptions.commandLine(device: nil, since: "2m", level: "info", grep: nil, follow: false,
                                               duration: nil, system: false, limit: 200, app: false)
        #expect(plain.since == .seconds(120) && plain.follow == nil && plain.level == .info)
        let follow = try LogOptions.commandLine(device: "ipad", since: "2m", level: "debug", grep: "x", follow: true,
                                                duration: nil, system: true, limit: 5, app: false)
        #expect(follow.follow == .seconds(30) && follow.level == .debug && follow.includeSystem && follow.device == "ipad")
        let explicit = try LogOptions.commandLine(device: nil, since: "2m", level: "info", grep: nil, follow: true,
                                                  duration: "2m", system: false, limit: 200, app: false)
        #expect(explicit.follow == .seconds(120))
    }

    /// `--follow` without `--for` streams 30s, or less when logs.maxFollow is shorter; it never trips the cap itself.
    @Test func defaultFollowIsCappedAtMaxFollow() throws {
        let capped = try LogOptions.commandLine(device: nil, since: "2m", level: "info", grep: nil, follow: true,
                                                duration: nil, system: false, limit: 200, app: false,
                                                maxFollow: .seconds(10))
        #expect(capped.follow == .seconds(10))
        let roomy = try LogOptions.commandLine(device: nil, since: "2m", level: "info", grep: nil, follow: true,
                                               duration: nil, system: false, limit: 200, app: false,
                                               maxFollow: .seconds(300))
        #expect(roomy.follow == .seconds(30))
        // An explicit --for is kept as given, so LogService can reject one longer than logs.maxFollow.
        let explicit = try LogOptions.commandLine(device: nil, since: "2m", level: "info", grep: nil, follow: true,
                                                  duration: "20s", system: false, limit: 200, app: false,
                                                  maxFollow: .seconds(10))
        #expect(explicit.follow == .seconds(20))
    }

    @Test func logOptionsRejectBadCombinations() {
        let forWithoutFollow = #expect(throws: XcdError.self) {
            try LogOptions.commandLine(device: nil, since: "2m", level: "info", grep: nil, follow: false,
                                       duration: "10s", system: false, limit: 200, app: false)
        }
        #expect(forWithoutFollow?.message == "--for only applies with --follow")
        let level = #expect(throws: XcdError.self) {
            try LogOptions.commandLine(device: nil, since: "2m", level: "verbose", grep: nil, follow: false,
                                       duration: nil, system: false, limit: 200, app: false)
        }
        #expect(level?.message == "--level verbose is not one of: default, info, debug")
        let limit = #expect(throws: XcdError.self) {
            try LogOptions.commandLine(device: nil, since: "2m", level: "info", grep: nil, follow: false,
                                       duration: nil, system: false, limit: 0, app: false)
        }
        #expect(limit?.message == "--limit must be at least 1")
        let badFor = #expect(throws: XcdError.self) {
            try LogOptions.commandLine(device: nil, since: "2m", level: "info", grep: nil, follow: true,
                                       duration: "later", system: false, limit: 200, app: false)
        }
        #expect(badFor?.message == "--for later is not a duration")
    }

    @Test func contextIncludesTheBuiltApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-ctx-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let state = WorktreeState(id: "id", name: "feat", project: "App", projectRoot: dir, path: dir, branch: "feat",
                                  xcode: nil, devices: [:], status: .ready, createdAt: Date())
        let ctx = WorktreeContext(location: ProjectLocation(projectRoot: dir, worktreeRoot: dir),
                                  config: try ConfigLoader.parse(main: BuildServiceTests.config), state: state)
        #expect(ContextInfo.build(ctx: ctx, device: "iphone").environment["XCD_APP_PATH"] == nil)
        let product = AppProduct(path: "/dd/App.app", bundleId: "dev.x.App", executableName: "App", platform: "iphonesimulator")
        try AppStateStore.save(AppState(builds: ["iphone": BuildRecord(scheme: "App", configuration: nil, product: product,
                                                                        finishedAt: Date())]), ctx.paths)
        let env = ContextInfo.build(ctx: ctx, device: "iphone").environment
        #expect(env["XCD_APP_PATH"] == "/dd/App.app")
        #expect(env["XCD_BUNDLE_ID"] == "dev.x.App")
    }

    @Test func contextCarriesTheOutputFormat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-ctx-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let state = WorktreeState(id: "id", name: "feat", project: "App", projectRoot: dir, path: dir, branch: "feat",
                                  xcode: nil, devices: [:], status: .ready, createdAt: Date())
        let ctx = WorktreeContext(location: ProjectLocation(projectRoot: dir, worktreeRoot: dir),
                                  config: try ConfigLoader.parse(main: BuildServiceTests.config), state: state)
        #expect(ContextInfo.build(ctx: ctx, device: nil).environment["XCD_OUTPUT"] == nil)
        #expect(ContextInfo.build(ctx: ctx, device: nil, output: .json).environment["XCD_OUTPUT"] == "json")
        let worktree = ContextInfo.worktree(state, output: .text).environment
        #expect(worktree["XCD_WORKTREE_NAME"] == "feat" && worktree["XCD_OUTPUT"] == "text")
        #expect(worktree["XCD_DERIVED_DATA"] == dir + "/.xcdev/DerivedData" && worktree["XCD_DEVICE"] == nil)
    }

    @Test func servicesTakeTheOutputFormatFromTheEnvironment() {
        let paths = GlobalPaths(base: "/tmp/xcd-none")
        #expect(Services(runner: SystemProcessRunner(), globalPaths: paths, currentDirectory: "/", environment: [:]).output == .text)
        #expect(Services(runner: SystemProcessRunner(), globalPaths: paths, currentDirectory: "/",
                         environment: ["XCD_OUTPUT": "json"]).output == .json)
    }
}
