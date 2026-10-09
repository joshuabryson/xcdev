import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// A script route: the project's own script, run from the worktree with the route's values
/// in its environment. xcd boots the simulator and leaves the app alone.
@Suite struct ScriptRouteTests {
    let worktree = FakeWorktree(prefix: "xcd open script")
    var fake: FakeProcessRunner { worktree.runner }
    static let config = """
    version: 1
    project: App.xcodeproj
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro" }
      mac: { platform: macOS }
    deeplinks:
      routes:
        seeded:
          description: "Seed an album and open it"
          run: ./scripts/seed.sh "$XCD_PARAM_TITLE"
          timeout: 90s
          params:
            title: { description: "The album's title" }
            note: { optional: true }
        settings/about:
          description: "Tap through to About"
          run: ./scripts/about.sh
    """
    static let command = "./scripts/seed.sh \"$XCD_PARAM_TITLE\""
    let seeded = OpenRequest.route(name: "seeded", values: ["title": "Two Words"])

    /// A context on a fake simulator, with nothing built.
    func context() throws -> WorktreeContext {
        let ctx = try worktree.context(Self.config, container: "App.xcodeproj")
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        fake.stub(["sh"])
        return ctx
    }

    func service(output: OutputFormat = .text) -> RouteService {
        let builds = BuildService(runner: fake, provisioner: worktree.provisioner, now: { Date(timeIntervalSince1970: 1_790_040_000) })
        let watcher = CrashWatcher(probe: FakeProbe(), locator: CrashReportLocator(directory: worktree.root + "/DiagnosticReports"),
                                   sleep: Instant.sleep)
        return RouteService(apps: RunService(builds: builds, watcher: watcher, sleep: Instant.sleep), output: output)
    }

    var script: Invocation? { fake.calls.last { $0.argv[0] == "sh" } }

    @Test func theScriptRunsFromTheWorktreeWithItsValuesInTheEnvironment() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        let report = try await service(output: .json).open(seeded, OpenOptions(), in: &ctx)
        let run = try #require(script)
        #expect(run.argv == ["sh", "-c", Self.command] && run.workingDirectory == ctx.location.worktreeRoot)
        #expect(run.timeout == .seconds(90) && !run.passthrough)
        let log = try #require(run.outputFile)
        #expect(log.hasPrefix(ctx.paths.logs + "/") && log.hasSuffix("-route-seeded.log"))
        let udid = try #require(ctx.state.devices["iphone"]?.udid)
        #expect(run.environment["XCD_ROUTE"] == "seeded" && run.environment["XCD_PARAM_TITLE"] == "Two Words")
        #expect(run.environment["XCD_PARAM_NOTE"] == nil)                   // optional and not given: unset, not empty
        #expect(run.environment["XCD_DEVICE"] == "iphone" && run.environment["XCD_UDID"] == udid)
        #expect(run.environment["XCD_WORKTREE"] == ctx.location.worktreeRoot && run.environment["XCD_OUTPUT"] == "json")
        #expect(run.environment["XCD_APP_PATH"] == nil && run.environment["XCD_BUNDLE_ID"] == nil)      // nothing is built
        #expect(report.app == OpenReport.App(state: .untouched, pid: nil, bundleId: nil, log: nil))
        #expect(report.scriptLog == log && report.failure == nil && report.linkSent == nil)
        #expect(report.text == """
        opened seeded  device=iphone (iPhone 18 Pro, iOS 27.0)  app=untouched
        script: \(Self.command)
        env: XCD_PARAM_TITLE='Two Words' XCD_ROUTE=seeded
        log: \(log)
        """)
    }

    /// The simulator is up before the script runs, and xcd does nothing to the app: no build, no launch, no link.
    @Test func theSimulatorIsBootedAndTheAppIsLeftAlone() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        _ = try await service().open(seeded, OpenOptions(), in: &ctx)
        let boot = try #require(fake.calls.firstIndex { $0.arguments.starts(with: ["simctl", "boot"]) })
        let run = try #require(fake.calls.firstIndex { $0.argv[0] == "sh" })
        #expect(boot < run)
        let touched = ["launch", "terminate", "openurl", "spawn", "install", "get_app_container"]
        #expect(!fake.calls.contains { $0.argv[0] == "ps" || touched.contains($0.arguments.dropFirst().first ?? "") })
    }

    @Test func aBuiltAppIsNamedToTheScript() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        let app = AppProduct(path: "/dd/SampleApp.app", bundleId: "dev.xcdev.SampleApp", executableName: "SampleApp",
                             platform: "iphonesimulator")
        try AppStateStore.save(AppState(builds: ["iphone": BuildRecord(scheme: "App", configuration: nil, product: app,
                                                                        finishedAt: Date())]), ctx.paths)
        let report = try await service().open(seeded, OpenOptions(), in: &ctx)
        #expect(script?.environment["XCD_APP_PATH"] == "/dd/SampleApp.app" && script?.environment["XCD_BUNDLE_ID"] == "dev.xcdev.SampleApp")
        #expect(report.app?.bundleId == "dev.xcdev.SampleApp" && report.app?.state == .untouched)
    }

    /// A route's name can hold `/`. Its log's name cannot.
    @Test func aGroupedRoutesLogHasAFlatName() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        let report = try await service().open(.route(name: "settings/about", values: [:]), OpenOptions(), in: &ctx)
        #expect(report.scriptLog?.hasSuffix("-route-settings-about.log") == true)
        #expect(script?.environment["XCD_ROUTE"] == "settings/about" && script?.timeout == .seconds(300))
    }

    @Test func aMacDeviceBootsNothing() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        let report = try await service().open(seeded, OpenOptions(device: "mac"), in: &ctx)
        #expect(fake.calls.map { $0.argv[0] } == ["sh"])
        #expect(script?.environment["XCD_DEVICE"] == "mac" && script?.environment["XCD_UDID"] == nil)
        #expect(report.deviceSummary == "mac (macOS)")
    }

    @Test func aScriptThatFailsIsRouteFailedWithItsLastLines() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        fake.stub(["sh"], exitCode: 3, stdout: (1...25).map { "line \($0)\n" }.joined())
        let svc = service()
        let error = await #expect(throws: XcdError.self) { _ = try await svc.open(seeded, OpenOptions(), in: &ctx) }
        #expect(error?.code == .routeFailed && error?.code.exitCode == 1)
        #expect(error?.message == "the script of route 'seeded' ran and exited 3")
        #expect(error?.next == "fix the script (its output is in the log), then run `xcd open seeded` again")
        let log = try #require(script?.outputFile)
        #expect(error?.details == ["script: \(Self.command)", "log: \(log)"] + (6...25).map { "line \($0)" })
    }

    /// 126 and 127 are the shell's "not executable" and "not found".
    @Test(arguments: [(127, "the script's command was not found; fix deeplinks.routes.seeded.run in .xcdev.yml (paths are relative to the worktree root), then run `xcd open seeded` again"),
                      (126, "the script is not executable; run `chmod +x` on it, then run `xcd open seeded` again")])
    func aScriptTheShellCannotRunSaysWhatToFix(exitCode: Int, next: String) async throws {
        defer { worktree.remove() }
        var ctx = try context()
        fake.stub(["sh"], exitCode: Int32(exitCode), stderr: "sh: ./scripts/seed.sh: no\n")
        let svc = service()
        let error = await #expect(throws: XcdError.self) { _ = try await svc.open(seeded, OpenOptions(), in: &ctx) }
        #expect(error?.code == .routeFailed && error?.next == next)
    }

    @Test func aScriptThatRunsPastItsTimeoutIsATimeout() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        fake.stub(["sh"]) { _ in throw XcdError(.timeout, "sh timed out after 90s") }
        let svc = service()
        let error = await #expect(throws: XcdError.self) { _ = try await svc.open(seeded, OpenOptions(), in: &ctx) }
        #expect(error?.code == .timeout && error?.message == "the script of route 'seeded' was stopped after 1m30s")
        #expect(error?.next == "raise deeplinks.routes.seeded.timeout in .xcdev.yml, or make the script faster")
        #expect(error?.details == ["script: \(Self.command)", "log: \(try #require(script?.outputFile))"])
    }

    /// A script that opens another route must not hand its own values on.
    @Test func aNestedXcdDoesNotInheritTheRoutesVariables() {
        let inherited = ["PATH": "/bin", "XCD_ROUTE": "outer", "XCD_PARAM_ID": "7", "XCD_PARAMETERS": "not xcd's", "XCD_DEVICE": "iphone"]
        #expect(ContextInfo.childEnvironment(inherited: inherited, overrides: ["XCD_ROUTE": "inner"])
                == ["PATH": "/bin", "XCD_PARAMETERS": "not xcd's", "XCD_ROUTE": "inner"])
        #expect(ContextInfo.childEnvironment(inherited: inherited, overrides: [:]) == ["PATH": "/bin", "XCD_PARAMETERS": "not xcd's"])
    }
}
