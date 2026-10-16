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

    func service(_ probe: FakeProbe = FakeProbe()) -> RouteService {
        let builds = BuildService(runner: fake, provisioner: worktree.provisioner, now: { Date(timeIntervalSince1970: 1_790_040_000) })
        let watcher = CrashWatcher(probe: probe, locator: CrashReportLocator(directory: worktree.root + "/DiagnosticReports"),
                                   sleep: Instant.sleep)
        return RouteService(apps: RunService(builds: builds, watcher: watcher, sleep: Instant.sleep), arrival: arrival)
    }

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
            try "Mac launched\n".write(toFile: inv.arguments[3], atomically: true, encoding: .utf8)
            running.set([4242])
            return ProcessOutput()
        }
    }

    /// The `open` and `kill` commands, in order.
    var steps: [[String]] { fake.calls.filter { ["open", "kill"].contains($0.argv[0]) }.map(\.argv) }

    /// The `open -n -g` command that starts the app with its output in `log`, up to the app or the link.
    func start(log: String, environment: [String] = []) -> [String] {
        ["open", "-n", "-g", "--stdout", log, "--stderr", log] + environment.flatMap { ["--env", $0] }
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
        #expect(steps == [start(log: log) + [app], ["open", "-g", "-a", app, Self.link]])
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
        #expect(steps == [["kill", "-TERM", "500"], start(log: log, environment: ["MODE=fresh"]) + [app, "--args", "-reset"],
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
                          + ["--env", "STEP=2", app, "--args", "-reset", "-startRoute", "onboarding/2"]])
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
                          start(log: log, environment: ["MODE=fresh"]) + ["-a", app, Self.link, "--args", "-reset"]])
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
        #expect(steps == [start(log: log) + ["-a", app, "SampleApp://direct"]])
        #expect(report.app?.state == .startedByLink && report.route == nil)
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

    /// UI driving does not reach a Mac app, so a route's `expect` is skipped there, and says so. An https link is
    /// handed straight to the app on a Mac, so there is nothing to note about Safari: the note says what every
    /// worktree's build of the app shares.
    @Test func theArrivalCheckIsSkippedOnAMac() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [500])
        let svc = service()
        let report = try await svc.open(.route(name: "checked", values: ["id": "Milk"]), OpenOptions(device: "mac"), in: &ctx)
        #expect(report.check == OpenReport.Check(target: "label~Milk", outcome: .skipped, seconds: nil,
                                                 reason: "the arrival check needs UI driving, which works on iPhone and iPad simulators only"))
        #expect(arrival.looks.isEmpty && report.failure == nil)
        let web = try await svc.open(.route(name: "web", values: [:]), OpenOptions(device: "mac"), in: &ctx)
        #expect(web.note == RunReport.sharedData(of: "dev.x.Mac") && steps.last == ["open", "-g", "-a", app, "https://example.com/item"])
        #expect(report.note == web.note && report.text.hasSuffix("\nnote: " + (web.note ?? "")))
    }

    /// A skipped check makes no look, so the watch's 2 s window (9 checks) is all that xcd watches: a Mac app that
    /// ends after it is not asked for again.
    @Test func aSkippedCheckDoesNotLengthenTheWatch() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try setUp(ctx, pids: [500])
        let report = try await service(FakeProbe(runningChecks: 9)).open(.route(name: "checked", values: ["id": "Milk"]), OpenOptions(device: "mac"), in: &ctx)
        #expect(report.check?.outcome == .skipped && report.failure == nil && report.exitedAfter == nil)
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
