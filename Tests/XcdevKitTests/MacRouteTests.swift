import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd open` for a Mac app: which `open` and `kill` commands run, in which order, and what is reported.
@Suite struct MacRouteTests {
    let worktree = FakeWorktree(prefix: "xcd open mac")
    var fake: FakeProcessRunner { worktree.runner }
    /// The pids `ps` lists for this build's app.
    let running = Shared<[Int32]>([])
    var app: String { worktree.root + "/Build/Products/Debug/Mac.app" }
    var product: AppProduct { AppProduct(path: app, bundleId: "dev.x.Mac", executableName: "Mac", platform: "macosx") }
    static let link = "sampleapp://sample/item?id=42"
    let item = OpenRequest.route(name: "item", values: ["id": "42"])

    func context() throws -> WorktreeContext { try worktree.context(RouteServiceTests.config, container: "App.xcodeproj") }

    let arrival = FakeArrival()

    func service(_ probe: FakeProbe = FakeProbe(), arrival: FakeArrival? = nil, isolation: MacIsolationService? = nil) -> RouteService {
        let builds = BuildService(runner: fake, provisioner: worktree.provisioner, now: { Date(timeIntervalSince1970: 1_790_040_000) })
        let watcher = CrashWatcher(probe: probe, locator: CrashReportLocator(directory: worktree.root + "/DiagnosticReports"),
                                   sleep: Instant.sleep)
        let apps = RunService(builds: builds, watcher: watcher, isolation: isolation ?? MacIsolationServiceTests.quiet(on: fake),
                              sleep: Instant.sleep)
        return RouteService(apps: apps, arrival: arrival ?? self.arrival)
    }

    /// A look before the link that does not see the element, then one after it that does.
    static func appearing() -> FakeArrival { FakeArrival([.success(.missing(onScreen: [], away: nil)), .success(.found(seconds: 0.6))]) }

    /// A built Mac app that registers `sampleapp`. `pids` are its running copies; starting it leaves 4242 as the only one.
    func setUp(_ ctx: WorktreeContext, pids: [Int32] = []) throws {
        try FileManager.default.createDirectory(atPath: app + "/Contents", withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleURLTypes": [["CFBundleURLSchemes": ["sampleapp"]]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
        try AppStateStore.save(AppState(builds: ["mac": BuildRecord(scheme: "App", configuration: nil, product: product,
                                                                     finishedAt: Date())]), ctx.paths)
        running.set(pids)
        fake.stub(["ps"]) { [running, product] _ in
            ProcessOutput(stdout: running.value.map { "  \($0) \(product.executablePath)\n" }.joined())
        }
        fake.stub(["kill"]) { [running] _ in
            running.set([])
            return ProcessOutput()
        }
        fake.stub(["open"]) { [running] inv in
            guard inv.arguments.first == "-n" else { return ProcessOutput() }      // a link for the copy that is up
            let log = inv.arguments.drop { $0 != "--stdout" }.dropFirst().first ?? ""
            try "Mac launched\n".write(toFile: log, atomically: true, encoding: .utf8)
            running.set([4242])
            return ProcessOutput()
        }
    }

    /// The `open` and `kill` commands, in order.
    var steps: [[String]] { fake.calls.filter { ["open", "kill"].contains($0.argv[0]) }.map(\.argv) }

    /// What every Mac launch ends with: App Nap off, then the preset's own arguments.
    func napOff(_ arguments: [String] = []) -> [String] { ["--args", "-NSAppSleepDisabled", "YES"] + arguments }

    /// The `open -n -g -j` command that starts the app with its output in `log`, up to the app or the link.
    func start(log: String, environment: [String] = []) -> [String] {
        ["open", "-n", "-g", "-j", "--stdout", log, "--stderr", log] + environment.flatMap { ["--env", $0] }
            + ["--env", "NSUnbufferedIO=YES", "--env", "OS_ACTIVITY_DT_MODE=YES"]
    }

    @Test func aLinkGoesToTheRunningCopyOfThisBuild() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [500])
        let report = try await service().open(item, OpenOptions(device: "mac"), in: &ctx)
        #expect(steps == [["open", "-g", "-a", app, Self.link]])            // by path, and kept in the background
        #expect(report.app == OpenReport.App(state: .running, pid: 500, bundleId: "dev.x.Mac", log: nil))
        #expect(report.text == "opened item  device=mac (macOS)  app=running  pid=500\nurl: \(Self.link)\nnote: \(RunReport.sharedData(of: "dev.x.Mac"))")
        #expect(report.linkSent == true && report.failure == nil)
    }

    @Test func anAppThatIsNotRunningIsStartedThenSentTheLink() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx)
        let report = try await service().open(item, OpenOptions(device: "mac"), in: &ctx)
        let log = try #require(report.app?.log)
        #expect(steps == [start(log: log) + [app] + napOff(), ["open", "-g", "-a", app, Self.link]])
        #expect(report.app?.state == .started && report.app?.pid == 4242 && report.linkSent == true)
        let record = try #require(try AppStateStore.load(ctx.paths).lastLaunch)
        #expect(record.target == "mac" && record.pid == 4242 && record.appLog == log)
    }

    @Test func aPresetRestartsTheRunningCopyThenTheLinkIsSent() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [500])
        let report = try await service().open(.route(name: "welcome", values: [:]), OpenOptions(device: "mac"), in: &ctx)
        let log = try #require(report.app?.log)
        #expect(steps == [["kill", "-TERM", "500"], start(log: log, environment: ["MODE=fresh"]) + [app] + napOff(["-reset"]),
                          ["open", "-g", "-a", app, "sampleapp://sample/welcome"]])
        #expect(report.app?.state == .restarted && report.preset == "fresh")
    }

    @Test func aLaunchRouteStartsTheMacAppWithItsArguments() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx)
        let report = try await service().open(.route(name: "start", values: ["step": "2"]), OpenOptions(device: "mac"), in: &ctx)
        let log = try #require(report.app?.log)
        // The preset's variables and the route's, in name order, with the two that capture output among them.
        #expect(steps == [start(log: log, environment: ["MODE=fresh"])
                          + ["--env", "STEP=2", app] + napOff(["-reset", "-startRoute", "onboarding/2"])])
        #expect(report.app?.state == .started && report.kind == .launch && report.linkSent == nil)
    }

    /// `--cold` on a Mac: xcd stops the app and starts it itself with the link attached, so its output is captured
    /// and a preset still applies. No second `open` follows.
    @Test func aColdLinkStartsTheMacAppWithTheLinkAttached() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [500])
        let report = try await service().open(item, OpenOptions(device: "mac", preset: "fresh", cold: true), in: &ctx)
        let log = try #require(report.app?.log)
        #expect(steps == [["kill", "-TERM", "500"],
                          start(log: log, environment: ["MODE=fresh"]) + ["-a", app, Self.link] + napOff(["-reset"])])
        #expect(report.app?.state == .startedByLink && report.app?.pid == 4242 && report.preset == "fresh")
        #expect(report.linkSent == true && report.failure == nil)
        #expect(try String(contentsOfFile: log, encoding: .utf8) == "Mac launched\n")
        #expect(try AppStateStore.load(ctx.paths).lastLaunch?.pid == 4242)
    }

    @Test func aColdLinkToAMacAppThatIsNotRunningStopsNothing() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx)
        let report = try await service().open(.url("SampleApp://direct"), OpenOptions(device: "mac", cold: true), in: &ctx)
        let log = try #require(report.app?.log)
        #expect(steps == [start(log: log) + ["-a", app, "SampleApp://direct"] + napOff()])
        #expect(report.app?.state == .startedByLink && report.route == nil)
    }

    static let suffixConfig = RouteServiceTests.config.replacingOccurrences(of: "mac: { platform: macOS }",
                                                                            with: "mac: { platform: macOS, isolation: suffix }")

    /// This build under `isolation: suffix`, with `pids` running from this worktree's copy as `ps` lists them: isolation
    /// that would copy the build (the real `ditto`, a stubbed `codesign`) and sees `apps` running, and the copy's path.
    func suffixed(_ ctx: WorktreeContext, pids: [Int32] = [],
                  apps: FakeRunningApps = FakeRunningApps()) throws -> (MacIsolationService, String) {
        try setUp(ctx, pids: pids)
        let isolation = try MacIsolationServiceTests.copying(app, on: fake, apps: apps,
                                                             extra: ["CFBundleURLTypes": [["CFBundleURLSchemes": ["sampleapp"]]]])
        let copy = ctx.paths.macCopies + "/Mac.app"
        fake.stub(["ps"]) { [running] _ in ProcessOutput(stdout: running.value.map { "  \($0) \(copy)/Contents/MacOS/Mac\n" }.joined()) }
        return (isolation, copy)
    }

    /// Under `isolation: suffix` a cold link starts this worktree's copy with the link attached. The scheme check reads
    /// the build's Info.plist, whose URL schemes the copy shares; `begin` makes the copy once the running one is
    /// stopped.
    @Test func openColdUnderSuffixLaunchesTheCopyWithTheLink() async throws {
        defer { worktree.remove() }
        var ctx = try worktree.context(Self.suffixConfig, container: "App.xcodeproj")
        let (isolation, copy) = try suffixed(ctx)
        let report = try await service(isolation: isolation).open(item, OpenOptions(device: "mac", cold: true), in: &ctx)
        let log = try #require(report.app?.log)
        #expect(steps == [start(log: log) + ["-a", copy, Self.link] + napOff()])
        #expect(report.app?.state == .startedByLink && report.app?.bundleId == "dev.x.Mac.xcd-feat")
        #expect(report.note == "isolation: dev.x.Mac.xcd-feat" && fake.calls.contains { $0.argv[0] == "codesign" })
        #expect(try AppStateStore.load(ctx.paths).lastLaunch?.bundleId == "dev.x.Mac.xcd-feat")
    }

    /// A link to this worktree's running copy goes to it as it is: the copy (missing here, so stale) is not made under
    /// the running process, and no other worktree's copy is looked for.
    @Test func aLinkToTheRunningCopyNeitherRemakesNorGuards() async throws {
        defer { worktree.remove() }
        var ctx = try worktree.context(Self.suffixConfig, container: "App.xcodeproj")
        let apps = FakeRunningApps()
        let (isolation, copy) = try suffixed(ctx, pids: [500], apps: apps)
        let report = try await service(isolation: isolation).open(item, OpenOptions(device: "mac"), in: &ctx)
        #expect(steps == [["open", "-g", "-a", copy, Self.link]])
        #expect(report.app == OpenReport.App(state: .running, pid: 500, bundleId: "dev.x.Mac.xcd-feat", log: nil))
        #expect(!fake.calls.contains { $0.argv[0] == "codesign" } && !FileManager.default.fileExists(atPath: copy))
        #expect(apps.queries.isEmpty && report.note == "isolation: dev.x.Mac.xcd-feat")
    }

    /// `open -a` would hand the app a link whose scheme it does not register, which no real link could do.
    @Test func aSchemeTheMacAppDoesNotRegisterIsRefused() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [500])
        let svc = service()
        let error = await #expect(throws: XcdError.self) { _ = try await svc.open(.url("other://x"), OpenOptions(device: "mac"), in: &ctx) }
        #expect(error?.code == .usage && error?.message == "dev.x.Mac does not register the scheme 'other'")
        #expect(steps.isEmpty)
    }

    @Test func aMacAppThatEndsAfterTheLinkIsAFailure() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [500])
        let report = try await service(FakeProbe(runningChecks: 1)).open(item, OpenOptions(device: "mac"), in: &ctx)
        #expect(report.failure?.code == .appCrashed)
        #expect(report.failure?.message == "the link was sent, and the app exited 0.2s later without a crash report")
    }

    /// The arrival check looks on a Mac as on a simulator, through the engine xcd runs itself: once before the link
    /// goes to the copy that is up, and once after. An https link is handed straight to
    /// the app on a Mac, so there is nothing to note about Safari: the note says what every worktree's build of the
    /// app shares.
    @Test func theArrivalCheckLooksOnAMacAsOnASimulator() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [500])
        let arrival = Self.appearing()
        let svc = service(arrival: arrival)
        let report = try await svc.open(.route(name: "checked", values: ["id": "Milk"]), OpenOptions(device: "mac"), in: &ctx)
        #expect(report.check == OpenReport.Check(target: "label~Milk", outcome: .appeared, seconds: 0.6, reason: nil))
        #expect(arrival.looks.map(\.device) == ["mac", "mac"] && report.failure == nil)
        let web = try await svc.open(.route(name: "web", values: [:]), OpenOptions(device: "mac"), in: &ctx)
        #expect(web.note == RunReport.sharedData(of: "dev.x.Mac") && steps.last == ["open", "-g", "-a", app, "https://example.com/item"])
        #expect(report.note == web.note && report.text.hasSuffix("\nnote: " + (web.note ?? "")))
    }

    /// A look lengthens the watch on a Mac as on a simulator: the app is asked for again once the look is done, so a
    /// Mac app alive through the watch's 2 s window (9 checks) and gone after the look is this command's to report.
    @Test func aLookOnAMacLengthensTheWatch() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [500])
        let report = try await service(FakeProbe(runningChecks: 9), arrival: Self.appearing())
            .open(.route(name: "checked", values: ["id": "Milk"]), OpenOptions(device: "mac"), in: &ctx)
        #expect(report.check?.outcome == .appeared && report.failure?.code == .appCrashed && report.exitedAfter != nil)
    }

    @Test func aMacAppThatWasNeverBuiltSaysWhatToRun() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        let svc = service()
        let error = await #expect(throws: XcdError.self) { _ = try await svc.open(item, OpenOptions(device: "mac"), in: &ctx) }
        #expect(error?.code == .appNotBuilt && error?.next == "run `xcd build --device mac` (or `xcd run --device mac`)")
        #expect(fake.calls.isEmpty)
    }
}
