import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct HookTests {
    let worktree = FakeWorktree(prefix: "xcd hook")
    var fake: FakeProcessRunner { worktree.runner }
    /// Hooks run through a real /bin/sh; everything else stays on the fake.
    var hooks: HookRunner { hooks() }

    func hooks(timeout: Duration = .seconds(1800)) -> HookRunner {
        HookRunner(runner: RoutingRunner(fake: fake, realExecutables: ["sh"]), output: .json, timeout: timeout,
                   now: { Date(timeIntervalSince1970: 1_790_040_000) })
    }

    func context(hooks yaml: String, container: String? = "App.xcodeproj") throws -> WorktreeContext {
        try worktree.context(BuildServiceTests.config + "\nhooks:\n" + yaml, container: container)
    }

    @Test func runsFromTheWorktreeWithTheContextAndLogsOutput() async throws {
        defer { worktree.remove() }
        let ctx = try context(hooks: #"  pre-build: 'test -d App.xcodeproj && echo "in the worktree"; echo "$XCD_WORKTREE_NAME $XCD_DEVICE $XCD_OUTPUT"; echo warn >&2'"#)
        let log = try #require(try await hooks.run(.preBuild, in: ctx, device: "iphone"))
        #expect(log.hasPrefix(worktree.root + "/.xcdev/logs/") && log.hasSuffix("-hook-pre-build.log"))
        #expect(try String(contentsOfFile: log, encoding: .utf8) == "in the worktree\nfeat iphone json\nwarn\n")
    }

    @Test func anUnconfiguredHookDoesNothing() async throws {
        defer { worktree.remove() }
        let ctx = try worktree.context(BuildServiceTests.config, container: "App.xcodeproj")
        #expect(try await hooks.run(.preBuild, in: ctx, device: nil) == nil)
        #expect(fake.calls.isEmpty)
    }

    @Test func aFailingHookIsHookFailedWithItsLogTail() async throws {
        defer { worktree.remove() }
        let ctx = try context(hooks: "  pre-build: 'echo generating; echo bad template >&2; exit 3'")
        let error = await #expect(throws: XcdError.self) { try await hooks.run(.preBuild, in: ctx, device: nil) }
        #expect(error?.code == .hookFailed)
        #expect(error?.message == "the pre-build hook failed (exit 3)")
        #expect(error?.next == "fix the hook (its output is in the log), or remove hooks.pre-build from .xcdev.yml, then re-run")
        #expect(error?.details.first == "hook: echo generating; echo bad template >&2; exit 3")
        #expect(error?.details.dropFirst().first?.hasPrefix("log: \(worktree.root)/.xcdev/logs/") == true)
        #expect(Array(error?.details.suffix(2) ?? []) == ["generating", "bad template"])
    }

    @Test func aMissingCommandSaysSo() async throws {
        defer { worktree.remove() }
        let ctx = try context(hooks: "  post-launch: ./scripts/grant-permissions.sh")
        let error = await #expect(throws: XcdError.self) { try await hooks.run(.postLaunch, in: ctx, device: nil) }
        #expect(error?.message == "the post-launch hook failed (exit 127)")
        #expect(error?.next?.hasPrefix("the hook's command was not found; fix hooks.post-launch") == true)
    }

    @Test func preBuildRunsBeforeXcodebuildAndAFailureStopsTheBuild() async throws {
        defer { worktree.remove() }
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        let xcodebuild = FakeXcodebuild(runner: fake)
        xcodebuild.onRun(.init(buildResults: Fixture.string("build-results-succeeded.json")))
        xcodebuild.onBuildSettings(Fixture.string("build-settings.json"))
        // Runs before the simulator and the app are resolved, so their variables are unset even once they exist.
        var ctx = try context(hooks: #"  pre-build: 'printf "%s|%s|%s|%s|%s|%s|%s\n" "$XCD_DEVICE" "$XCD_UDID" "$XCD_RUNTIME" "$XCD_APP_PATH" "$XCD_BUNDLE_ID" "$DEVELOPER_DIR" "$XCD_OUTPUT" >> pre-build.txt'"#)
        let builds = BuildService(runner: fake, provisioner: worktree.provisioner, hooks: hooks)

        #expect(try await builds.build(BuildOptions(), in: &ctx).succeeded)
        #expect(ctx.state.devices["iphone"]?.udid != nil)
        #expect(try await builds.build(BuildOptions(), in: &ctx).succeeded)
        let line = "iphone|||||/Applications/Xcode.app/Contents/Developer|json\n"
        #expect(try String(contentsOfFile: worktree.root + "/pre-build.txt", encoding: .utf8) == line + line)
        #expect(xcodebuild.runs.count == 2)

        var failing = try context(hooks: "  pre-build: exit 1")
        let error = await #expect(throws: XcdError.self) { try await builds.build(BuildOptions(device: "mac"), in: &failing) }
        #expect(error?.code == .hookFailed)
        #expect(xcodebuild.runs.count == 2)          // the failed hook stopped the third build
    }

    @Test func preBuildRunsBeforeTheProjectIsResolved() async throws {
        defer { worktree.remove() }
        let xcodebuild = FakeXcodebuild(runner: fake)
        xcodebuild.onRun(.init(buildResults: Fixture.string("build-results-succeeded.json")))
        xcodebuild.onBuildSettings(Fixture.string("build-settings.json"))
        // Like xcodegen or tuist: the project doesn't exist until the hook generates it.
        var ctx = try context(hooks: "  pre-build: mkdir App.xcodeproj", container: nil)
        let builds = BuildService(runner: fake, provisioner: worktree.provisioner, hooks: hooks)

        #expect(try await builds.build(BuildOptions(device: "mac"), in: &ctx).succeeded)
        #expect(xcodebuild.runs.count == 1)

        try FileManager.default.removeItem(atPath: worktree.root + "/App.xcodeproj")
        _ = try await TestService(builds: builds).test(TestOptions(device: "mac"), in: &ctx)
        #expect(xcodebuild.runs.count == 2)
    }

    @Test func preBuildIsNotRunByClean() async throws {
        defer { worktree.remove() }
        let xcodebuild = FakeXcodebuild(runner: fake)
        xcodebuild.onRun(.init())
        var ctx = try context(hooks: "  pre-build: touch ran.txt")
        let builds = BuildService(runner: fake, provisioner: worktree.provisioner, hooks: hooks)
        _ = try await builds.clean(scheme: nil, deep: false, in: &ctx)
        _ = try await builds.clean(scheme: nil, deep: true, in: &ctx)
        #expect(!FileManager.default.fileExists(atPath: worktree.root + "/ran.txt"))
    }

    @Test func testRunsPreBuildToo() async throws {
        defer { worktree.remove() }
        let xcodebuild = FakeXcodebuild(runner: fake)
        var ctx = try context(hooks: "  pre-build: exit 4")
        let tests = TestService(builds: BuildService(runner: fake, provisioner: worktree.provisioner, hooks: hooks))
        let error = await #expect(throws: XcdError.self) { try await tests.test(TestOptions(device: "mac"), in: &ctx) }
        #expect(error?.message == "the pre-build hook failed (exit 4)")
        #expect(xcodebuild.runs.isEmpty)
    }

    func launchable(hooks yaml: String, timeout: Duration = .seconds(1800)) throws -> (RunService, WorktreeContext) {
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        fake.stub(["xcrun", "simctl", "install"])
        fake.stub(["xcrun", "simctl", "launch"]) { inv in
            try "".write(toFile: String(inv.arguments[3].dropFirst("--stdout=".count)), atomically: true, encoding: .utf8)
            return ProcessOutput(stdout: "dev.xcdev.SampleApp: 4242\n")
        }
        let ctx = try context(hooks: yaml)
        try AppStateStore.save(AppState(builds: ["iphone": BuildRecord(scheme: "App", configuration: nil,
                                                                        product: RunServiceTests.product, finishedAt: Date())]),
                               ctx.paths)
        let builds = BuildService(runner: fake, provisioner: worktree.provisioner, hooks: hooks(timeout: timeout))
        let apps = RunService(builds: builds, watcher: CrashWatcher(probe: FakeProbe(), locator: CrashReportLocator(directory: worktree.root),
                                                                    sleep: { _ in }), sleep: { _ in })
        return (apps, ctx)
    }

    @Test func postLaunchRunsAfterTheLaunchWithTheAppsContext() async throws {
        defer { worktree.remove() }
        var (apps, ctx) = try launchable(hooks: #"  post-launch: 'echo "$XCD_BUNDLE_ID $XCD_UDID $XCD_OUTPUT" > launched.txt'"#)
        let report = try await apps.launch(device: nil, options: LaunchOptions(), in: &ctx)
        #expect(report.status == .running)
        let udid = try #require(ctx.state.devices["iphone"]?.udid)
        #expect(try String(contentsOfFile: worktree.root + "/launched.txt", encoding: .utf8) == "dev.xcdev.SampleApp \(udid) json\n")

        var failing = try context(hooks: "  post-launch: exit 2")
        let error = await #expect(throws: XcdError.self) { try await apps.launch(device: nil, options: LaunchOptions(), in: &failing) }
        #expect(error?.code == .hookFailed)
        #expect(error?.details.last == "the app is still running (pid 4242); stop it with `xcd terminate`")
    }

    @Test func aPostLaunchTimeoutAlsoSaysTheAppIsStillRunning() async throws {
        defer { worktree.remove() }
        var (apps, ctx) = try launchable(hooks: "  post-launch: sleep 10", timeout: .milliseconds(300))
        let error = await #expect(throws: XcdError.self) { try await apps.launch(device: nil, options: LaunchOptions(), in: &ctx) }
        #expect(error?.code == .timeout)
        #expect(error?.message == "the post-launch hook timed out after 0.3s")
        #expect(error?.next == "make hooks.post-launch in .xcdev.yml finish sooner, then re-run")
        #expect(error?.details.first == "hook: sleep 10")
        #expect(error?.details.last == "the app is still running (pid 4242); stop it with `xcd terminate`")
    }
}
