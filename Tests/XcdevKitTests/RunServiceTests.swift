import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct RunServiceTests {
    let worktree = FakeWorktree(prefix: "xcd run")
    var fake: FakeProcessRunner { worktree.runner }
    var crashDir: String { worktree.root + "/DiagnosticReports" }
    static let config = BuildServiceTests.config + """

    presets:
      onboarding: { args: ["-resetOnboarding", "YES"], env: { API_ENV: staging, GREETING: preset } }
    """
    static let product = AppProduct(path: "/dd/SampleApp.app", bundleId: "dev.xcdev.SampleApp",
                                    executableName: "SampleApp", platform: "iphonesimulator")
    static let macProduct = AppProduct(path: "/dd/Mac.app", bundleId: "dev.x.Mac", executableName: "Mac", platform: "macosx")

    func context(_ yaml: String = RunServiceTests.config) throws -> WorktreeContext {
        try worktree.context(yaml, container: "App.xcodeproj")
    }

    func service(_ probe: FakeProbe = FakeProbe(), now: @escaping @Sendable () -> Date = { Date() }) -> RunService {
        let builds = BuildService(runner: fake, provisioner: worktree.provisioner, now: now)
        return RunService(builds: builds, watcher: CrashWatcher(probe: probe, locator: CrashReportLocator(directory: crashDir),
                                                                sleep: { _ in }),
                          sleep: { _ in })
    }

    /// Simulators, a succeeding xcodebuild, and simctl app commands. Launch writes `appOutput` to the app log.
    func setUp(pid: Int32 = 4242, appOutput: String = "SampleApp launched greeting=hi\n") throws -> (FakeSimulators, FakeXcodebuild) {
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        let xcodebuild = FakeXcodebuild(runner: fake)
        xcodebuild.onRun(.init(buildResults: Fixture.string("build-results-succeeded.json")))
        xcodebuild.onBuildSettings(Fixture.string("build-settings.json"))
        fake.stub(["xcrun", "simctl", "install"])
        fake.stub(["xcrun", "simctl", "uninstall"])
        fake.stub(["xcrun", "simctl", "terminate"])
        fake.stub(["xcrun", "simctl", "launch"]) { inv in
            let log = String(inv.arguments[3].dropFirst("--stdout=".count))
            try appOutput.write(toFile: log, atomically: true, encoding: .utf8)
            return ProcessOutput(stdout: "dev.xcdev.SampleApp: \(pid)\n")
        }
        return (sims, xcodebuild)
    }

    /// Records a Mac build of `macProduct` so `launch`/`install` need no xcodebuild.
    func recordMacBuild(_ ctx: WorktreeContext) throws {
        try AppStateStore.save(AppState(builds: ["mac": BuildRecord(scheme: "App", configuration: nil,
                                                                     product: Self.macProduct, finishedAt: Date())]),
                               ctx.paths)
    }

    @Test func runBuildsBootsInstallsLaunchesAndRecords() async throws {
        defer { worktree.remove() }
        let (sims, _) = try setUp()
        var ctx = try context()
        let report = try await service().run(BuildOptions(), noBuild: false,
                                             launch: LaunchOptions(preset: "onboarding", arguments: ["-extra"],
                                                                   environment: ["GREETING": "hi"]),
                                             in: &ctx)
        #expect(report.status == .running && report.failure == nil)
        #expect(report.pid == 4242 && report.bundleId == "dev.xcdev.SampleApp")
        let udid = try #require(ctx.state.devices["iphone"]?.udid)
        #expect(sims.devices.first { $0.udid == udid }?.state == "Booted")
        let launch = try #require(fake.calls.first { $0.arguments.starts(with: ["simctl", "launch"]) })
        #expect(Array(launch.arguments.suffix(3)) == ["-resetOnboarding", "YES", "-extra"])
        #expect(launch.environment["SIMCTL_CHILD_GREETING"] == "hi")
        #expect(launch.environment["SIMCTL_CHILD_API_ENV"] == "staging")
        let installIndex = try #require(fake.calls.firstIndex { $0.arguments.starts(with: ["simctl", "install"]) })
        let launchIndex = try #require(fake.calls.firstIndex { $0.arguments.starts(with: ["simctl", "launch"]) })
        #expect(installIndex < launchIndex)
        let record = try #require(try AppStateStore.load(ctx.paths).lastLaunch)
        #expect(record.pid == 4242 && record.target == "iphone" && record.appLog == report.appLog)
        #expect(report.text.hasPrefix("build succeeded  scheme=App device=iphone (iPhone 18 Pro, iOS 27.0)"))
        #expect(report.text.contains("\nlaunched dev.xcdev.SampleApp  device=iphone (iPhone 18 Pro, iOS 27.0)  pid=4242  running after 5.0s\n"))
        #expect(report.note?.contains("temporary") == true)       // this test's worktree is under $TMPDIR
    }

    @Test func launchTimeIsTakenBeforeTheAppStarts() async throws {
        defer { worktree.remove() }
        _ = try setUp()
        var ctx = try context()
        let clock = Counter()
        fake.stub(["xcrun", "simctl", "launch"]) { inv in
            let log = String(inv.arguments[3].dropFirst("--stdout=".count))
            try "".write(toFile: log, atomically: true, encoding: .utf8)
            _ = clock.increment()      // time moves on while the app starts
            return ProcessOutput(stdout: "dev.xcdev.SampleApp: 4242\n")
        }
        let builds = BuildService(runner: fake, provisioner: worktree.provisioner,
                                  now: { Date(timeIntervalSince1970: 1_790_040_000 + Double(clock.value) * 100) })
        let svc = RunService(builds: builds, watcher: CrashWatcher(probe: FakeProbe(), locator: CrashReportLocator(directory: crashDir),
                                                                   sleep: { _ in }), sleep: { _ in })
        try AppStateStore.save(AppState(builds: ["iphone": BuildRecord(scheme: "App", configuration: nil, product: Self.product,
                                                                        finishedAt: Date())]), ctx.paths)
        _ = try await svc.launch(device: nil, options: LaunchOptions(), in: &ctx)
        let record = try #require(try AppStateStore.load(ctx.paths).lastLaunch)
        #expect(record.launchedAt == Date(timeIntervalSince1970: 1_790_040_000))
    }

    @Test func unknownPresetFailsBeforeBuilding() async throws {
        defer { worktree.remove() }
        let (_, xcodebuild) = try setUp()
        var ctx = try context()
        let error = await #expect(throws: XcdError.self) {
            try await service().run(BuildOptions(), noBuild: false, launch: LaunchOptions(preset: "nope"), in: &ctx)
        }
        #expect(error?.code == .usage)
        #expect(error?.next == "use one of: onboarding")
        #expect(xcodebuild.runs.isEmpty)
    }

    @Test func noBuildWithoutABuildSaysWhichBuildToRun() async throws {
        defer { worktree.remove() }
        _ = try setUp()
        var ctx = try context()
        let error = await #expect(throws: XcdError.self) {
            try await service().run(BuildOptions(device: "iphone"), noBuild: true, launch: LaunchOptions(), in: &ctx)
        }
        #expect(error?.code == .appNotBuilt)
        #expect(error?.message == "the app has not been built for iphone in this worktree")
        #expect(error?.next == "run `xcd build --device iphone` (or `xcd run --device iphone`)")
    }

    @Test func buildFailureStopsTheRun() async throws {
        defer { worktree.remove() }
        let (_, xcodebuild) = try setUp()
        xcodebuild.onRun(.init(exitCode: 65, buildResults: Fixture.string("build-results-failed.json")))
        var ctx = try context()
        let report = try await service().run(BuildOptions(), noBuild: false, launch: LaunchOptions(), in: &ctx)
        #expect(report.status == .buildFailed)
        #expect(report.failure?.code == .buildFailed)
        #expect(report.failure?.next == "fix the errors and re-run `xcd run`")
        #expect(!fake.calls.contains { $0.arguments.starts(with: ["simctl", "launch"]) })
    }

    @Test func aCrashIsAFailureWithTheReportAndTheAppsLastWords() async throws {
        defer { worktree.remove() }
        _ = try setUp(pid: 46606, appOutput: "SampleApp launched greeting=none\nSampleApp/SampleAppApp.swift:14: Fatal error: SampleApp crashed on purpose\n")
        try FileManager.default.createDirectory(atPath: crashDir, withIntermediateDirectories: true)
        // The report is written at the launch time the fixed clock gives, so how long the fake build takes doesn't matter.
        let launchedAt = Date(timeIntervalSince1970: 1_790_040_000)
        let ips = crashDir + "/SampleApp-2026-09-30-195619.ips"
        try Fixture.string("crash-sim.ips").write(toFile: ips, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: launchedAt], ofItemAtPath: ips)
        var ctx = try context()
        let report = try await service(FakeProbe(runningChecks: 4), now: { launchedAt })
            .run(BuildOptions(), noBuild: false, launch: LaunchOptions(arguments: ["-crashOnLaunch"]), in: &ctx)
        #expect(report.status == .crashed)
        #expect(report.failure?.code == .appCrashed)
        #expect(report.failure?.message == "the app crashed 1.0s after launch")
        #expect(report.appOutput?.last == "SampleApp/SampleAppApp.swift:14: Fatal error: SampleApp crashed on purpose")
        let text = report.text
        #expect(text.contains("\napp crashed  bundle=dev.xcdev.SampleApp device=iphone (iPhone 18 Pro, iOS 27.0)  pid=46606 after 1.0s\n"))
        #expect(text.contains("\ncrash: EXC_BREAKPOINT (SIGTRAP), Trace/BPT trap: 5\n  libswiftCore.dylib  _assertionFailure"))
        #expect(text.contains("\napp output (last lines):\n  SampleApp launched greeting=none\n  SampleApp/SampleAppApp.swift:14: Fatal error"))
        #expect(text.contains("\nreport: \(crashDir)/SampleApp-2026-09-30-195619.ips\n"))
    }

    @Test func anExitWithoutAReportIsStillAFailure() async throws {
        defer { worktree.remove() }
        _ = try setUp()
        var ctx = try context()
        let report = try await service(FakeProbe(runningChecks: 0)).run(BuildOptions(), noBuild: false, launch: LaunchOptions(), in: &ctx)
        #expect(report.status == .exited)
        #expect(report.failure?.code == .appCrashed)
        #expect(report.failure?.next == "check the app's output with `xcd logs --app` and its logs with `xcd logs`, then re-run `xcd run`")
    }

    @Test func installLaunchTerminateAndUninstallUseTheRecordedBuild() async throws {
        defer { worktree.remove() }
        _ = try setUp()
        var ctx = try context()
        try AppStateStore.save(AppState(builds: ["iphone": BuildRecord(scheme: "App", configuration: nil, product: Self.product,
                                                                        finishedAt: Date())]), ctx.paths)
        let svc = service()
        #expect(try await svc.install(device: nil, in: &ctx).text == "installed dev.xcdev.SampleApp  device=iphone")
        #expect(try await svc.launch(device: nil, options: LaunchOptions(), in: &ctx).pid == 4242)
        #expect(try await svc.terminate(device: nil, in: &ctx).text == "terminated dev.xcdev.SampleApp  device=iphone")
        fake.stub(["xcrun", "simctl", "terminate"], exitCode: 3, stderr: "found nothing to terminate")
        #expect(try await svc.terminate(device: nil, in: &ctx).action == "not running")
        #expect(try await svc.uninstall(device: nil, in: &ctx).action == "uninstalled")
        #expect(!fake.calls.contains { $0.argv.starts(with: ["xcrun", "xcodebuild", "build"]) })
    }

    @Test func aSchemeWithoutAnAppHasNothingToRun() async throws {
        defer { worktree.remove() }
        _ = try setUp()
        var ctx = try context()
        try AppStateStore.save(AppState(builds: ["iphone": BuildRecord(scheme: "Lib", configuration: nil, product: nil,
                                                                        finishedAt: Date())]), ctx.paths)
        let error = await #expect(throws: XcdError.self) { try await service().install(device: nil, in: &ctx) }
        #expect(error?.code == .usage)
        #expect(error?.message == "scheme Lib builds no app, so there is nothing to install or run")
    }

    @Test func macAppsLaunchFromDerivedDataWithNothingToInstall() async throws {
        defer { worktree.remove() }
        _ = try setUp()
        var ctx = try context()
        try recordMacBuild(ctx)
        let polls = Counter()
        // Poll 1: stop a running copy (none). Poll 2: pids before `open`. Poll 3: the new process.
        fake.stub(["ps"]) { _ in ProcessOutput(stdout: polls.increment() > 2 ? "  77 /dd/Mac.app/Contents/MacOS/Mac\n" : "") }
        fake.stub(["open"])
        let install = try await service().install(device: "mac", in: &ctx)
        #expect(install.action == "nothing to install")
        let report = try await service().launch(device: "mac", options: LaunchOptions(), in: &ctx)
        #expect(report.pid == 77 && report.targetSummary == "mac (macOS)")
        #expect(report.note == "every worktree's build of this app has the bundle id dev.x.Mac, so they share its data on this Mac: its UserDefaults, "
                    + "its container (~/Library/Containers/dev.x.Mac) if it is sandboxed or its Application Support and Caches folders if not, "
                    + "its app group containers, and its keychain items; what a run in one worktree changes, a run in another sees")
        #expect(report.text.hasSuffix("\nnote: " + (report.note ?? "")))
        #expect(!fake.calls.contains { $0.argv[0] == "kill" })
    }

    /// Every ref is stale after a relaunch, so a Mac launch deletes the saved ones.
    @Test func aMacLaunchForgetsTheSavedRefs() async throws {
        defer { worktree.remove() }
        _ = try setUp()
        var ctx = try context()
        try recordMacBuild(ctx)
        let file = MacRefStore.file(ctx.paths, device: "mac")
        try MacRefStore.save(MacRefs(refs: [:], lastRef: 3), to: file)
        let polls = Counter()
        fake.stub(["ps"]) { _ in ProcessOutput(stdout: polls.increment() > 2 ? "  77 /dd/Mac.app/Contents/MacOS/Mac\n" : "") }
        fake.stub(["open"])
        let svc = service()
        let app = try await svc.prepare("mac", boot: true, in: &ctx)
        _ = try await svc.begin(app, LaunchPlan(), in: &ctx)
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    /// A simulator is shown with `xcd sim open`; this is refused before anything is booted.
    @Test func showOnASimulatorIsRefusedBeforeItIsBooted() async throws {
        defer { worktree.remove() }
        _ = try setUp()
        var ctx = try context()
        let error = await #expect(throws: XcdError.self) {
            try await service().launch(device: "iphone", options: LaunchOptions(show: true), in: &ctx)
        }
        #expect(error?.code == .usage && error?.message == "--show is for a Mac app")
        #expect(error?.next == "a simulator is shown with `xcd sim open`")
        #expect(!fake.calls.contains { $0.arguments.contains("boot") })
    }

    /// `xcd run --show` on a simulator is refused before the build, not after it.
    @Test func runWithShowOnASimulatorIsRefusedBeforeAnyBuildOrBoot() async throws {
        defer { worktree.remove() }
        _ = try setUp()
        var ctx = try context()
        let error = await #expect(throws: XcdError.self) {
            try await service().run(BuildOptions(device: "iphone"), noBuild: false, launch: LaunchOptions(show: true), in: &ctx)
        }
        #expect(error?.code == .usage && error?.next == "a simulator is shown with `xcd sim open`")
        #expect(!fake.calls.contains { $0.argv.contains("xcodebuild") || $0.arguments.contains("boot") })
    }

    @Test func macRunStopsTheRunningCopyBeforeLaunching() async throws {
        defer { worktree.remove() }
        _ = try setUp()
        var ctx = try context()
        try recordMacBuild(ctx)
        let exe = Self.macProduct.executablePath
        let killed = Counter()
        fake.stub(["kill"]) { _ in killed.increment(); return ProcessOutput() }
        fake.stub(["ps"]) { _ in
            // The old copy (50) runs until it is sent SIGTERM; then `open` starts 77.
            var out = killed.value == 0 ? "  50 \(exe)\n" : ""
            if fake.calls.contains(where: { $0.argv[0] == "open" }) { out += "  77 \(exe)\n" }
            return ProcessOutput(stdout: out)
        }
        fake.stub(["open"])
        let report = try await service().launch(device: "mac", options: LaunchOptions(), in: &ctx)
        #expect(report.pid == 77)
        let kill = try #require(fake.calls.firstIndex { $0.argv[0] == "kill" })
        let open = try #require(fake.calls.firstIndex { $0.argv[0] == "open" })
        #expect(fake.calls[kill].arguments == ["-TERM", "50"])
        #expect(kill < open)
    }

    @Test func aMacAppThatCrashesBeforeItIsSeenIsACrash() async throws {
        defer { worktree.remove() }
        _ = try setUp()
        var ctx = try context()
        try recordMacBuild(ctx)
        fake.stub(["ps"])                                        // the app dies before `ps` sees it
        fake.stub(["open"]) { inv in
            try "Mac/MacApp.swift:9: Fatal error: crashed in init\n".write(toFile: inv.arguments[4], atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(atPath: crashDir, withIntermediateDirectories: true)
            try Fixture.crashReport(in: nil).write(toFile: crashDir + "/Mac-2026-09-30-195619.ips", atomically: true, encoding: .utf8)
            return ProcessOutput()
        }
        let report = try await service().launch(device: "mac", options: LaunchOptions(), in: &ctx)
        #expect(report.status == .crashed)
        #expect(report.failure?.code == .appCrashed)
        #expect(report.pid == 46606 && report.crash?.path == crashDir + "/Mac-2026-09-30-195619.ips")
        #expect(report.appOutput == ["Mac/MacApp.swift:9: Fatal error: crashed in init"])
        #expect(try AppStateStore.load(ctx.paths).lastLaunch?.pid == 46606)
    }

    /// A simulator's copy of the app can crash under the same name at the same moment. That is not this start's crash.
    @Test func aSimulatorsCrashIsNotTakenForTheMacAppsCrash() async throws {
        defer { worktree.remove() }
        _ = try setUp()
        var ctx = try context()
        try recordMacBuild(ctx)
        fake.stub(["ps"])
        fake.stub(["open"]) { _ in
            try FileManager.default.createDirectory(atPath: crashDir, withIntermediateDirectories: true)
            try Fixture.string("crash-sim.ips").write(toFile: crashDir + "/Mac-2026-09-30-195619.ips", atomically: true, encoding: .utf8)
            return ProcessOutput()
        }
        let error = await #expect(throws: XcdError.self) {
            try await service().launch(device: "mac", options: LaunchOptions(), in: &ctx)
        }
        #expect(error?.code == .subprocessFailed && error?.message == "Mac did not start within 5s")
    }

    @Test func aMacAppThatNeverStartsWithoutACrashReportFails() async throws {
        defer { worktree.remove() }
        _ = try setUp()
        var ctx = try context()
        try recordMacBuild(ctx)
        fake.stub(["ps"])
        fake.stub(["open"])
        let error = await #expect(throws: XcdError.self) {
            try await service().launch(device: "mac", options: LaunchOptions(), in: &ctx)
        }
        #expect(error?.code == .subprocessFailed)
        #expect(error?.message == "Mac did not start within 5s")
        #expect(error?.next?.hasPrefix("read the app log: \(ctx.paths.logs)/") == true)
    }

    /// `xcd open` starts the app through the same steps and puts its own step before the crash watch.
    @Test func beginStartsAndRecordsTheAppWithoutWatchingIt() async throws {
        defer { worktree.remove() }
        _ = try setUp()
        var ctx = try context()
        var state = AppState()
        state.builds["iphone"] = BuildRecord(scheme: "App", configuration: nil, product: Self.product, finishedAt: Date())
        try AppStateStore.save(state, ctx.paths)
        let svc = service(FakeProbe(runningChecks: 0))                       // a watch would see the app gone at once
        let app = try await svc.prepare(nil, boot: true, in: &ctx)
        #expect(app.target.name == "iphone" && app.product == Self.product)
        let started = try await svc.begin(app, LaunchPlan(arguments: ["-x"], environment: ["K": "v"]), in: &ctx)
        #expect(started.pid == 4242 && started.crashedAtLaunch == nil)
        #expect(try AppStateStore.load(ctx.paths).lastLaunch?.appLog == started.appLog)
        let launch = try #require(fake.calls.last { $0.arguments.starts(with: ["simctl", "launch"]) })
        #expect(launch.arguments.last == "-x" && launch.environment["SIMCTL_CHILD_K"] == "v")
        #expect(try await svc.outcome(of: started, app.product, window: .seconds(5)) == .exited(after: 0, crash: nil))
    }

    @Test func presetsBecomeALaunchPlan() throws {
        let config = try ConfigLoader.parse(main: Self.config)
        let plan = try LaunchOptions(preset: "onboarding", arguments: ["-extra"], environment: ["GREETING": "hi"],
                                     crashWindow: .seconds(2)).plan(config: config)
        #expect(plan == LaunchPlan(arguments: ["-resetOnboarding", "YES", "-extra"],
                                   environment: ["API_ENV": "staging", "GREETING": "hi"], crashWindow: .seconds(2)))
        #expect(throws: XcdError.self) { try LaunchOptions(preset: "nope").plan(config: config) }
    }

    @Test func environmentPairsParse() throws {
        #expect(try LaunchOptions.parseEnvironment(["A=1", "B=x=y", "C="]) == ["A": "1", "B": "x=y", "C": ""])
        let error = #expect(throws: XcdError.self) { try LaunchOptions.parseEnvironment(["NOPE"]) }
        #expect(error?.code == .usage)
        #expect(error?.message == "--env NOPE is not KEY=VALUE")
    }
}
