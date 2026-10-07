import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd open` against a fake simulator: which simctl commands run, in which order, and what is reported.
@Suite struct RouteServiceTests {
    let worktree = FakeWorktree(prefix: "xcd open")
    var fake: FakeProcessRunner { worktree.runner }
    var crashDir: String { worktree.root + "/DiagnosticReports" }
    /// The pids `ps` lists for the installed app.
    let running = Shared<[Int32]>([])
    static let container = "/sims/U1/data/Containers/Bundle/Application/AB12/SampleApp.app"
    static let config = """
    version: 1
    project: App.xcodeproj
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro" }
      mac: { platform: macOS }
    presets:
      fresh: { args: ["-reset"], env: { MODE: fresh } }
      other: { args: ["-other"] }
    deeplinks:
      vars:
        base: "sampleapp://sample"
      routes:
        item:
          description: "Show one item"
          url: "{base}/item?id={id}"
          params: { id: {} }
        checked:
          description: "Show one item and check it"
          url: "{base}/item?id={id}"
          expect: "label~{id}"
          params: { id: {} }
        welcome:
          description: "The welcome screen of a fresh install"
          url: "{base}/welcome"
          preset: fresh
        web:
          description: "A web link"
          url: "https://example.com/item"
        start:
          description: "Start at a step"
          launch: { args: ["-startRoute", "onboarding/{step}"], env: { STEP: "{step}" } }
          preset: fresh
          params: { step: { default: 1 } }
        seeded:
          description: "Seed and open"
          run: ./seed.sh
    """

    func context(hooks: String = "") throws -> WorktreeContext {
        try worktree.context(Self.config + hooks, container: "App.xcodeproj")
    }

    func service(_ probe: FakeProbe = FakeProbe(), hooks: HookRunner? = nil,
                 progress: @escaping @Sendable (String) -> Void = { _ in }) -> RouteService {
        let builds = BuildService(runner: fake, provisioner: worktree.provisioner, progress: progress,
                                  now: { Date(timeIntervalSince1970: 1_790_040_000) }, hooks: hooks)
        let watcher = CrashWatcher(probe: probe, locator: CrashReportLocator(directory: crashDir), sleep: { _ in })
        return RouteService(apps: RunService(builds: builds, watcher: watcher, sleep: { _ in }))
    }

    /// A built, installed app on a fake simulator. `pids` are its running processes; a launch replaces them with 4242.
    func setUp(_ ctx: WorktreeContext, pids: [Int32] = [], product: AppProduct? = nil) throws {
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        let app = product ?? AppProduct(path: "/dd/SampleApp.app", bundleId: "dev.xcdev.SampleApp", executableName: "SampleApp",
                                        platform: "iphonesimulator")
        try AppStateStore.save(AppState(builds: ["iphone": BuildRecord(scheme: "App", configuration: nil, product: app,
                                                                        finishedAt: Date())]), ctx.paths)
        running.set(pids)
        fake.stub(["xcrun", "simctl", "get_app_container"], stdout: Self.container + "\n")
        fake.stub(["ps"]) { [running] _ in
            ProcessOutput(stdout: running.value.map { "  \($0) \(Self.container)/SampleApp\n" }.joined())
        }
        fake.stub(["xcrun", "simctl", "spawn"])
        fake.stub(["xcrun", "simctl", "openurl"])
        fake.stub(["xcrun", "simctl", "terminate"]) { [running] _ in
            running.set([])
            return ProcessOutput()
        }
        fake.stub(["xcrun", "simctl", "launch"]) { [running] inv in
            try "SampleApp launched\n".write(toFile: String(inv.arguments[3].dropFirst("--stdout=".count)), atomically: true, encoding: .utf8)
            running.set([4242])
            return ProcessOutput(stdout: "dev.xcdev.SampleApp: 4242\n")
        }
    }

    /// The simctl subcommands that changed the app, in order. Booting the clone and looking for the app are left out.
    var steps: [String] {
        fake.calls.filter { $0.argv.starts(with: ["xcrun", "simctl"]) }.map { $0.arguments[1] }
            .filter { ["launch", "terminate", "spawn", "openurl", "install"].contains($0) }
    }

    /// The simulator the recorded crash report came from: none of these tests' own.
    static let otherSimulator = "C268DCFB-3E56-4C43-8947-B25ED3833F7E"

    /// Writes a crash report for SampleApp, dated at the service's clock, and returns its path. It is the recorded report
    /// of process `pid` on simulator `udid`; a later `stamp` makes it the newer file.
    func writeCrashReport(pid: Int32 = 46606, udid: String = otherSimulator, stamp: String = "2026-09-30-195619") throws -> String {
        try FileManager.default.createDirectory(atPath: crashDir, withIntermediateDirectories: true)
        let ips = crashDir + "/SampleApp-\(stamp).ips"
        let text = Fixture.string("crash-sim.ips").replacingOccurrences(of: Self.otherSimulator, with: udid)
            .replacingOccurrences(of: "\"pid\" : 46606,", with: "\"pid\" : \(pid),")
        try text.write(toFile: ips, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_790_040_000)], ofItemAtPath: ips)
        return ips
    }

    /// The UDID of this worktree's simulator, cloned now instead of by the first command.
    func clone(_ ctx: inout WorktreeContext) async throws -> String {
        try await worktree.provisioner.ensure("iphone", in: &ctx).udid
    }

    func call(_ subcommand: String) -> Invocation? { fake.calls.last { $0.arguments.dropFirst().first == subcommand } }

    func item(_ id: String = "42") -> OpenRequest { .route(name: "item", values: ["id": id]) }

    @Test func aLinkGoesToTheAppThatIsAlreadyRunning() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [500])
        let said = Shared<[String]>([])
        let report = try await service(progress: { line in said.change { $0.append(line) } }).open(item(), OpenOptions(), in: &ctx)
        #expect(steps == ["spawn", "openurl"])                              // approved, then sent; never relaunched
        #expect(call("spawn")?.arguments.suffix(3) == ["com.apple.CoreSimulator.CoreSimulatorBridge-->sampleapp", "-string", "dev.xcdev.SampleApp"])
        #expect(call("openurl")?.arguments.last == "sampleapp://sample/item?id=42")
        #expect(report.app == OpenReport.App(state: "running", pid: 500, bundleId: "dev.xcdev.SampleApp", log: nil))
        #expect(report.failure == nil && report.check == nil)
        #expect(report.text == "opened item  device=iphone (iPhone 18 Pro, iOS 27.0)  app=running  pid=500\nurl: sampleapp://sample/item?id=42")
        #expect(said.value == ["delivered to dev.xcdev.SampleApp (pid 500); watching 2.0s for a crash"])
        #expect(try AppStateStore.load(ctx.paths).lastLaunch == nil)        // xcd did not start it, so nothing is recorded
    }

    /// The copy xcd started earlier has a log; a link sent to it names that log.
    @Test func aLinkToTheCopyXcdStartedNamesItsLog() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx)
        let svc = service()
        let first = try await svc.open(item("1"), OpenOptions(), in: &ctx)
        let second = try await svc.open(item("2"), OpenOptions(), in: &ctx)
        #expect(first.app?.state == "started" && second.app?.state == "running" && second.app?.pid == 4242)
        #expect(second.app?.log == first.app?.log && second.app?.log != nil)
    }

    @Test func anAppThatIsNotRunningIsStartedThenSentTheLink() async throws {
        defer { worktree.remove() }
        var ctx = try context(hooks: "\nhooks:\n  post-launch: ./grant.sh\n")
        try setUp(ctx)
        fake.stub(["sh"])
        let said = Shared<[String]>([])
        let report = try await service(hooks: HookRunner(runner: fake), progress: { line in said.change { $0.append(line) } })
            .open(item(), OpenOptions(), in: &ctx)
        #expect(steps == ["launch", "spawn", "openurl"])
        let launch = try #require(fake.calls.firstIndex { $0.arguments.starts(with: ["simctl", "launch"]) })
        let hook = try #require(fake.calls.firstIndex { $0.argv == ["sh", "-c", "./grant.sh"] })
        let link = try #require(fake.calls.firstIndex { $0.arguments.starts(with: ["simctl", "openurl"]) })
        #expect(launch < hook && hook < link)                               // launch, hook, link
        #expect(Array(try #require(call("launch")).arguments.suffix(2)) == [try #require(ctx.state.devices["iphone"]?.udid), "dev.xcdev.SampleApp"])
        #expect(report.app?.state == "started" && report.app?.pid == 4242)
        let log = try #require(report.app?.log)
        #expect(log.hasPrefix(ctx.paths.logs + "/") && log.hasSuffix("-app.log"))
        #expect(said.value.last == "delivered to dev.xcdev.SampleApp (pid 4242); watching 5.0s for a crash")
        let record = try #require(try AppStateStore.load(ctx.paths).lastLaunch)
        #expect(record.pid == 4242 && record.appLog == log && record.target == "iphone")
    }

    @Test func aPresetRestartsTheAppEvenWhenItIsRunning() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [500])
        let report = try await service().open(.route(name: "welcome", values: [:]), OpenOptions(), in: &ctx)
        #expect(steps == ["launch", "spawn", "openurl"])
        #expect(call("launch")?.arguments.last == "-reset" && call("launch")?.environment["SIMCTL_CHILD_MODE"] == "fresh")
        #expect(report.app?.state == "restarted" && report.app?.pid == 4242 && report.preset == "fresh")
        #expect(report.text.contains("\npreset: fresh\n"))
    }

    @Test func thePresetFlagReplacesTheRoutesPresetAndRestartsForAnyLink() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [500])
        let svc = service()
        let welcome = try await svc.open(.route(name: "welcome", values: [:]), OpenOptions(preset: "other"), in: &ctx)
        #expect(call("launch")?.arguments.last == "-other" && call("launch")?.environment["SIMCTL_CHILD_MODE"] == nil)
        #expect(welcome.preset == "other" && welcome.app?.state == "restarted")
        let direct = try await svc.open(.url("sampleapp://x"), OpenOptions(preset: "fresh"), in: &ctx)
        #expect(call("launch")?.arguments.last == "-reset" && direct.app?.state == "restarted" && direct.route == nil)
        let unknown = await #expect(throws: XcdError.self) { _ = try await svc.open(item(), OpenOptions(preset: "nope"), in: &ctx) }
        #expect(unknown?.code == .usage && unknown?.next == "use one of: fresh, other")
    }

    @Test func aLaunchRouteStartsTheAppWithThePresetsArgumentsThenItsOwn() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [500])
        let svc = service()
        let report = try await svc.open(.route(name: "start", values: ["step": "3"]), OpenOptions(cold: true), in: &ctx)
        #expect(steps == ["launch"])                                        // no link, and --cold changes nothing
        #expect(Array(try #require(call("launch")).arguments.suffix(3)) == ["-reset", "-startRoute", "onboarding/3"])
        #expect(call("launch")?.environment["SIMCTL_CHILD_MODE"] == "fresh" && call("launch")?.environment["SIMCTL_CHILD_STEP"] == "3")
        #expect(report.app?.state == "restarted" && report.kind == "launch" && report.url == nil)
        #expect(report.arguments == ["-reset", "-startRoute", "onboarding/3"] && report.environment == ["MODE": "fresh", "STEP": "3"])
        // --preset replaces the route's preset; the route's own arguments and environment still apply.
        _ = try await svc.open(.route(name: "start", values: [:]), OpenOptions(preset: "other"), in: &ctx)
        #expect(Array(try #require(call("launch")).arguments.suffix(3)) == ["-other", "-startRoute", "onboarding/1"])
        #expect(call("launch")?.environment["SIMCTL_CHILD_MODE"] == nil && call("launch")?.environment["SIMCTL_CHILD_STEP"] == "1")
    }

    @Test func aStartedAppThatWasNotRunningIsStartedNotRestarted() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx)
        #expect(try await service().open(.route(name: "start", values: [:]), OpenOptions(), in: &ctx).app?.state == "started")
    }

    /// `--cold`: the running copy is stopped and the link itself starts the app. xcd never launches it.
    @Test func aColdLinkStartsTheApp() async throws {
        defer { worktree.remove() }
        var ctx = try context(hooks: "\nhooks:\n  post-launch: ./grant.sh\n")
        try setUp(ctx, pids: [500])
        fake.stub(["sh"])
        let looks = Counter()
        // The stopped copy is still listed for one look after the link; then the system's new process appears.
        fake.stub(["xcrun", "simctl", "terminate"])
        fake.stub(["ps"]) { _ in
            ProcessOutput(stdout: "  \(looks.increment() <= 2 ? 500 : 600) \(Self.container)/SampleApp\n")
        }
        let report = try await service(hooks: HookRunner(runner: fake)).open(item(), OpenOptions(cold: true), in: &ctx)
        #expect(steps == ["terminate", "spawn", "openurl"])
        #expect(report.app == OpenReport.App(state: "started-by-link", pid: 600, bundleId: "dev.xcdev.SampleApp", log: nil))
        #expect(report.failure == nil)
        let record = try #require(try AppStateStore.load(ctx.paths).lastLaunch)
        #expect(record.pid == 600 && record.launchedAt == Date(timeIntervalSince1970: 1_790_040_000))
        // The system started this run, so its app log holds a note instead of an older run's output.
        #expect(try String(contentsOfFile: record.appLog, encoding: .utf8).contains("started by a link (`xcd open --cold`)"))
        let link = try #require(fake.calls.firstIndex { $0.arguments.starts(with: ["simctl", "openurl"]) })
        let hook = try #require(fake.calls.firstIndex { $0.argv == ["sh", "-c", "./grant.sh"] })
        #expect(link < hook)                                                // the post-launch hook runs once the app is up
    }

    @Test func aColdLinkToAnAppThatIsNotRunningStopsNothing() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx)
        fake.stub(["xcrun", "simctl", "openurl"]) { [running] _ in
            running.set([700])
            return ProcessOutput()
        }
        let report = try await service().open(item(), OpenOptions(cold: true), in: &ctx)
        #expect(steps == ["spawn", "openurl"] && report.app?.pid == 700 && report.app?.state == "started-by-link")
    }

    @Test func aColdLinkThatStartsNothingIsRouteFailed() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx)
        let svc = service()
        let error = await #expect(throws: XcdError.self) { _ = try await svc.open(item(), OpenOptions(cold: true), in: &ctx) }
        #expect(error?.code == .routeFailed && error?.code.exitCode == 1)
        #expect(error?.message == "the link was sent, but it did not start dev.xcdev.SampleApp within 30s")
        #expect(error?.next == "check that the app handles the link when it is not running, and read its log with `xcd logs`")
        #expect(fake.calls.filter { $0.argv[0] == "ps" }.count == 61)       // one look before the link, then 60
        #expect(try AppStateStore.load(ctx.paths).lastLaunch == nil)
        let web = await #expect(throws: XcdError.self) {
            _ = try await svc.open(.route(name: "web", values: [:]), OpenOptions(cold: true), in: &ctx)
        }
        #expect(web?.next?.contains("opens in Safari") == true)
    }

    /// The cold path is where link bugs live. An app that dies on the link before xcd ever sees its process did
    /// start: that is a crash, not a link that started nothing.
    @Test func aColdLinkTheAppDiesOnAtOnceIsACrash() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx)
        let udid = try await clone(&ctx)
        let ips = crashDir + "/SampleApp-2026-09-30-195619.ips"
        let test = self
        fake.stub(["xcrun", "simctl", "openurl"]) { _ in
            _ = try test.writeCrashReport(udid: udid)                       // the app dies as soon as the link arrives
            return ProcessOutput()
        }
        let report = try await service().open(item(), OpenOptions(cold: true), in: &ctx)
        #expect(report.failure?.code == .appCrashed && report.failure?.message == "the link was sent, and the app crashed 0.0s later")
        #expect(report.app?.state == "started-by-link" && report.app?.pid == 46606 && report.crash?.path == ips)
        #expect(fake.calls.filter { $0.argv[0] == "ps" }.count == 2)        // found on the first look after the link
    }

    /// A crash report that was already there when the link was sent belongs to an earlier run.
    @Test func anEarlierCrashReportIsNotTakenForThisStart() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx)
        let udid = try await clone(&ctx)
        _ = try writeCrashReport(udid: udid)
        let svc = service()
        let error = await #expect(throws: XcdError.self) { _ = try await svc.open(item(), OpenOptions(cold: true), in: &ctx) }
        #expect(error?.code == .routeFailed)
        fake.stub(["xcrun", "simctl", "openurl"]) { [running] _ in
            running.set([700])
            return ProcessOutput()
        }
        let report = try await svc.open(item(), OpenOptions(cold: true), in: &ctx)
        #expect(report.failure == nil && report.app?.pid == 700)
    }

    /// The reports folder is shared by every simulator: another worktree's copy of the app can crash during the wait.
    @Test func anotherSimulatorsCrashIsNotThisLinksStart() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx)
        let test = self
        fake.stub(["xcrun", "simctl", "openurl"]) { _ in
            _ = try test.writeCrashReport()                                 // a copy of SampleApp on another simulator
            return ProcessOutput()
        }
        let svc = service()
        let error = await #expect(throws: XcdError.self) { _ = try await svc.open(item(), OpenOptions(cold: true), in: &ctx) }
        #expect(error?.code == .routeFailed && error?.message == "the link was sent, but it did not start dev.xcdev.SampleApp within 30s")
        #expect(try AppStateStore.load(ctx.paths).lastLaunch == nil)
    }

    @Test func anotherSimulatorsCrashDoesNotHideThisLinksStart() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx)
        let test = self
        fake.stub(["xcrun", "simctl", "openurl"]) { _ in
            _ = try test.writeCrashReport()
            return ProcessOutput()
        }
        let looks = Counter()
        fake.stub(["ps"]) { _ in                                            // this simulator's process: the fourth look
            ProcessOutput(stdout: looks.increment() <= 3 ? "" : "  700 \(Self.container)/SampleApp\n")
        }
        let report = try await service().open(item(), OpenOptions(cold: true), in: &ctx)
        #expect(report.app == OpenReport.App(state: "started-by-link", pid: 700, bundleId: "dev.xcdev.SampleApp", log: nil))
        #expect(report.failure == nil && report.crash == nil)
    }

    /// Both reports are new: this simulator's is taken, whichever file is newer.
    @Test func thisSimulatorsCrashIsTakenEvenWhenAnotherSimulatorsIsNewer() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx)
        let udid = try await clone(&ctx)
        let test = self
        fake.stub(["xcrun", "simctl", "openurl"]) { _ in
            _ = try test.writeCrashReport(pid: 777, udid: udid)
            _ = try test.writeCrashReport(pid: 888, stamp: "2026-09-30-195700")
            return ProcessOutput()
        }
        let report = try await service().open(item(), OpenOptions(cold: true), in: &ctx)
        #expect(report.failure?.code == .appCrashed && report.app?.pid == 777 && report.crash?.pid == 777)
        #expect(report.crash?.path == crashDir + "/SampleApp-2026-09-30-195619.ips")
    }

    /// The report that was already there is this simulator's newest, not another simulator's newer one.
    @Test func anEarlierReportIsThisSimulatorsEvenWhenAnotherSimulatorsIsNewer() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx)
        let udid = try await clone(&ctx)
        _ = try writeCrashReport(pid: 777, udid: udid)
        _ = try writeCrashReport(pid: 888, stamp: "2026-09-30-195700")
        let svc = service()
        let error = await #expect(throws: XcdError.self) { _ = try await svc.open(item(), OpenOptions(cold: true), in: &ctx) }
        #expect(error?.code == .routeFailed)
    }

    /// The system starts a cold app, so launch arguments cannot be passed: refused before the device is touched.
    @Test func coldWithAPresetIsRefusedOnASimulator() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [500])
        let svc = service()
        let flag = await #expect(throws: XcdError.self) { _ = try await svc.open(item(), OpenOptions(preset: "fresh", cold: true), in: &ctx) }
        #expect(flag?.code == .usage && flag?.next == "drop --cold or --preset")
        #expect(flag?.message == "--cold cannot be combined with the preset 'fresh' on a simulator: the system starts the app, so launch arguments cannot be passed")
        let route = await #expect(throws: XcdError.self) {
            _ = try await svc.open(.route(name: "welcome", values: [:]), OpenOptions(cold: true), in: &ctx)
        }
        #expect(route?.code == .usage && route?.next == "run it without --cold: this route has a preset")
        #expect(fake.calls.isEmpty)
    }

    @Test func aCrashAfterTheLinkIsAFailureWithTheReport() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [46606])
        let ips = try writeCrashReport()
        let report = try await service(FakeProbe(runningChecks: 2)).open(item(), OpenOptions(), in: &ctx)
        #expect(report.failure?.code == .appCrashed)
        #expect(report.failure?.message == "the link was sent, and the app crashed 0.5s later")
        #expect(report.crash?.path == ips && report.exitedAfter == 0.5 && report.appOutput == nil)
        #expect(report.text.contains("\napp crashed 0.5s later\ncrash: EXC_BREAKPOINT (SIGTRAP), Trace/BPT trap: 5\n"))
        #expect(Renderer.report(report, command: "open", format: .text).hasSuffix("\nnext: fix the crash (see the frames and report above), then run `xcd open` again"))
    }

    /// A launch route that dies in its window shows what the app printed, since xcd captured it.
    @Test func aLaunchRouteThatExitsShowsTheAppsLastWords() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx)
        let report = try await service(FakeProbe(runningChecks: 0)).open(.route(name: "start", values: [:]), OpenOptions(), in: &ctx)
        #expect(report.failure?.code == .appCrashed && report.appOutput == ["SampleApp launched"])
        #expect(report.failure?.message == "the app was started with the route's arguments, and the app exited 0.0s later without a crash report")
    }

    @Test func aSchemeTheBuiltAppDoesNotRegisterIsRefusedBeforeAnythingIsSent() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        let app = worktree.root + "/Build/SampleApp.app"
        try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleURLTypes": [["CFBundleURLSchemes": ["SampleApp"]]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: URL(fileURLWithPath: app + "/Info.plist"))
        try setUp(ctx, product: AppProduct(path: app, bundleId: "dev.xcdev.SampleApp", executableName: "SampleApp", platform: "iphonesimulator"))
        let svc = service()
        let error = await #expect(throws: XcdError.self) { _ = try await svc.open(.url("other://x"), OpenOptions(), in: &ctx) }
        #expect(error?.code == .usage && error?.message == "dev.xcdev.SampleApp does not register the scheme 'other'")
        #expect(steps.isEmpty)
        // The app spells its scheme with capitals and the route does not: the system matches them, and so does xcd.
        _ = try await svc.open(item(), OpenOptions(), in: &ctx)
        #expect(call("spawn")?.arguments.contains("com.apple.CoreSimulator.CoreSimulatorBridge-->sampleapp") == true)
        _ = try await svc.open(.route(name: "web", values: [:]), OpenOptions(), in: &ctx)
        #expect(call("openurl")?.arguments.last == "https://example.com/item")
    }

    @Test func anAppThatIsNotInstalledOrNotBuiltSaysWhatToRun() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx)
        fake.stub(["xcrun", "simctl", "get_app_container"], exitCode: 2, stderr: LinkDeliveryTests.notInstalled)
        let svc = service()
        for request in [item(), .route(name: "start", values: [:])] {
            let error = await #expect(throws: XcdError.self) { _ = try await svc.open(request, OpenOptions(), in: &ctx) }
            #expect(error?.code == .simulatorFailed && error?.next == "install and start it with `xcd run`")
        }
        #expect(steps.isEmpty)
        try AppStateStore.save(AppState(), ctx.paths)
        let unbuilt = await #expect(throws: XcdError.self) { _ = try await svc.open(item(), OpenOptions(device: "iphone"), in: &ctx) }
        #expect(unbuilt?.code == .appNotBuilt && unbuilt?.next == "run `xcd build --device iphone` (or `xcd run --device iphone`)")
    }

    /// A dry run resolves the route, so every mistake still shows, and runs no process at all.
    @Test func aDryRunTouchesNothing() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        let svc = service()
        let report = try await svc.open(item("a b"), OpenOptions(dryRun: true), in: &ctx)
        #expect(report.text == "would open item  device=iphone\nurl: sampleapp://sample/item?id=a%20b")
        #expect(report.dryRun && report.app == nil)
        let launch = try await svc.open(.route(name: "start", values: [:]), OpenOptions(device: "mac", dryRun: true), in: &ctx)
        #expect(launch.text == "would open start  device=mac\nargs: -reset -startRoute onboarding/1\nenv: MODE=fresh STEP=1\npreset: fresh")
        let script = try await svc.open(.route(name: "seeded", values: [:]), OpenOptions(dryRun: true), in: &ctx)
        #expect(script.text == "would open seeded  device=iphone\nscript: ./seed.sh\nenv: XCD_ROUTE=seeded")
        let missing = await #expect(throws: XcdError.self) { _ = try await svc.open(.route(name: "item", values: [:]), OpenOptions(dryRun: true), in: &ctx) }
        #expect(missing?.code == .usage && missing?.message == "route 'item' needs id")
        let device = await #expect(throws: XcdError.self) { _ = try await svc.open(item(), OpenOptions(device: "ipad", dryRun: true), in: &ctx) }
        #expect(device?.code == .deviceUnknown)
        #expect(fake.calls.isEmpty && ctx.state.devices.isEmpty)
    }

    @Test func mistakesAreReportedBeforeTheDeviceIsTouched() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [500])
        let svc = service()
        for request in [OpenRequest.route(name: "nope", values: [:]), .route(name: "item", values: [:]), .list] {
            let error = await #expect(throws: XcdError.self) { _ = try await svc.open(request, OpenOptions(), in: &ctx) }
            #expect(error?.code == .usage)
        }
        #expect(fake.calls.isEmpty)
    }

    /// For now: a route's `expect` is named but not checked, and script routes and Mac apps say they come later.
    @Test func whatThisVersionDoesNotDoYetSaysSo() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [500])
        let svc = service()
        let checked = try await svc.open(.route(name: "checked", values: ["id": "Milk"]), OpenOptions(), in: &ctx)
        #expect(checked.check == OpenReport.Check(target: "label~Milk", outcome: "skipped", seconds: nil,
                                                 reason: "the arrival check is not in this version; use `xcd ui wait 'label~Milk'`"))
        #expect(checked.failure == nil)
        let script = await #expect(throws: XcdError.self) { _ = try await svc.open(.route(name: "seeded", values: [:]), OpenOptions(), in: &ctx) }
        #expect(script?.code == .usage && script?.message == "route 'seeded' runs a script, which this version of xcd cannot do yet")
        for flags in [OpenOptions(preset: "fresh"), OpenOptions(cold: true)] {
            let refused = await #expect(throws: XcdError.self) { _ = try await svc.open(.route(name: "seeded", values: [:]), flags, in: &ctx) }
            #expect(refused?.code == .usage && refused?.message.hasSuffix("does not apply to a script route: its script starts the app itself") == true)
        }
        try AppStateStore.save(AppState(builds: ["mac": BuildRecord(scheme: "App", configuration: nil,
            product: AppProduct(path: "/dd/Mac.app", bundleId: "dev.x.Mac", executableName: "Mac", platform: "macosx"), finishedAt: Date())]), ctx.paths)
        let mac = await #expect(throws: XcdError.self) { _ = try await svc.open(item(), OpenOptions(device: "mac"), in: &ctx) }
        #expect(mac?.code == .platformUnsupported)
        #expect(mac?.next == "until it can, send the link yourself: /usr/bin/open -g -a /dd/Mac.app 'sampleapp://sample/item?id=42'")
    }

    @Test func theListComesFromTheConfig() throws {
        defer { worktree.remove() }
        let report = service().list(in: try context())
        #expect(report.routes.map(\.name) == ["checked", "item", "seeded", "start", "web", "welcome"] && report.worktree == "feat")
    }
}
