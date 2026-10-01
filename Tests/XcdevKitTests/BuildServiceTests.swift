import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct BuildServiceTests {
    let worktree = FakeWorktree(prefix: "xcd build")
    var fake: FakeProcessRunner { worktree.runner }
    var dir: String { worktree.root }
    static let config = """
    version: 1
    project: App.xcodeproj
    schemes: { app: App, test: AppTests }
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro" }
      mac: { platform: macOS }
    """

    func context(_ yaml: String = BuildServiceTests.config, container: String = "App.xcodeproj") throws -> WorktreeContext {
        try worktree.context(yaml, container: container)
    }

    func service() -> BuildService {
        BuildService(runner: fake, provisioner: worktree.provisioner, now: { Date(timeIntervalSince1970: 1_790_040_000) })
    }

    func setUp() throws -> (FakeSimulators, FakeXcodebuild) {
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        return (sims, FakeXcodebuild(runner: fake))
    }

    @Test func failedBuildReportsEveryErrorAndKeepsTheLog() async throws {
        defer { worktree.remove() }
        let (sims, xcodebuild) = try setUp()
        xcodebuild.onRun(.init(exitCode: 65, log: "** BUILD FAILED **\n", buildResults: Fixture.string("build-results-failed.json")))
        var ctx = try context()
        let report = try await service().build(BuildOptions(), in: &ctx)

        #expect(!report.succeeded)
        #expect(report.errors.count == 2)
        #expect(report.failure?.code == .buildFailed)
        #expect(report.failure?.message == "build failed with 2 errors")
        #expect(try String(contentsOfFile: report.log, encoding: .utf8) == "** BUILD FAILED **\n")
        #expect(report.log.hasPrefix(dir + "/.xcdev/logs/") && report.log.hasSuffix("-build.log"))
        #expect(report.resultBundle?.hasPrefix(dir + "/.xcdev/results/") == true)
        let udid = try #require(ctx.state.devices["iphone"]?.udid)
        #expect(sims.cloneCount == 1)
        let args = try #require(xcodebuild.runs.first).arguments
        #expect(args.starts(with: ["xcodebuild", "build", "-project", dir + "/App.xcodeproj", "-scheme", "App",
                                   "-destination", "id=\(udid)"]))
        #expect(!fake.calls.contains { $0.arguments.contains("-showBuildSettings") })
        #expect(try AppStateStore.load(ctx.paths).builds.isEmpty)
    }

    @Test func succeededBuildRecordsTheApp() async throws {
        defer { worktree.remove() }
        let (_, xcodebuild) = try setUp()
        xcodebuild.onRun(.init(buildResults: Fixture.string("build-results-succeeded.json")))
        xcodebuild.onBuildSettings(Fixture.string("build-settings.json"))
        var ctx = try context()
        let report = try await service().build(BuildOptions(), in: &ctx)

        #expect(report.succeeded && report.failure == nil)
        #expect(report.product?.bundleId == "dev.xcdev.SampleApp")
        #expect(report.warningCount == 1 && report.warnings == nil)
        #expect(report.text.contains("1 warning (xcd build --warnings)"))
        let record = try #require(try AppStateStore.load(ctx.paths).builds["iphone"])
        #expect(record.scheme == "App" && record.product == report.product)

        let verbose = try await service().build(BuildOptions(showWarnings: true), in: &ctx)
        #expect(verbose.warnings?.count == 1)
        #expect(!verbose.text.contains("(xcd build --warnings)"))
    }

    @Test func macDeviceBuildsForMacOSWithoutCloning() async throws {
        defer { worktree.remove() }
        let (sims, xcodebuild) = try setUp()
        xcodebuild.onRun(.init(buildResults: Fixture.string("build-results-succeeded.json")))
        var ctx = try context()
        let report = try await service().build(BuildOptions(device: "mac"), in: &ctx)
        #expect(report.targetSummary == "mac (macOS)")
        #expect(xcodebuild.runs.first?.arguments.contains("platform=macOS") == true)
        #expect(sims.cloneCount == 0)
    }

    @Test func packageWithoutDevicesBuildsForTheHostWithItsOnlyScheme() async throws {
        defer { worktree.remove() }
        let (_, xcodebuild) = try setUp()
        xcodebuild.onList(Fixture.string("xcodebuild-list-package.json"))
        xcodebuild.onRun(.init(buildResults: Fixture.string("build-results-succeeded.json")))
        var ctx = try context("version: 1\nproject: Package.swift", container: "Package.swift")
        let report = try await service().build(BuildOptions(), in: &ctx)
        #expect(report.target == "host" && report.targetSummary == "host (macOS)")
        #expect(report.scheme == "SamplePackage")
        #expect(report.product == nil)
        let run = try #require(xcodebuild.runs.first)
        #expect(run.workingDirectory == dir && !run.arguments.contains("-project"))
        #expect(try AppStateStore.load(ctx.paths).builds["host"]?.product == nil)
    }

    @Test func missingSchemeListsTheProjectsSchemes() async throws {
        defer { worktree.remove() }
        let (_, xcodebuild) = try setUp()
        xcodebuild.onList(#"{"project":{"schemes":["App","AppKit"]}}"#)
        var ctx = try context("version: 1\nproject: App.xcodeproj\ndevices: { mac: { platform: macOS } }")
        let error = await #expect(throws: XcdError.self) { try await service().build(BuildOptions(), in: &ctx) }
        #expect(error?.code == .usage)
        #expect(error?.next == "set schemes.app in .xcdev.yml to one of: App, AppKit (or pass --scheme)")
        let list = try #require(fake.calls.first { $0.arguments.contains("-list") }).arguments
        #expect(!list.contains("-derivedDataPath") && list.contains(ctx.paths.sourcePackages))
    }

    @Test func failureWithoutResultsPassesXcodebuildErrorsThrough() async throws {
        defer { worktree.remove() }
        let (_, xcodebuild) = try setUp()
        xcodebuild.onRun(.init(exitCode: 70, log: """
        Command line invocation:
            xcodebuild build -scheme App
        xcodebuild: error: The project named "App" does not contain a scheme named "Ap".

        """))
        var ctx = try context()
        let report = try await service().build(BuildOptions(device: "mac"), in: &ctx)
        #expect(report.errors == [Diagnostic(.error, "The project named \"App\" does not contain a scheme named \"Ap\".")])
        #expect(report.logTail == nil)
        #expect(report.failure?.code == .buildFailed)
    }

    @Test func failureWithNothingToReportShowsTheLogTail() async throws {
        defer { worktree.remove() }
        let (_, xcodebuild) = try setUp()
        xcodebuild.onRun(.init(exitCode: 74, log: "line one\n\nline two\n"))
        var ctx = try context()
        let report = try await service().build(BuildOptions(device: "mac"), in: &ctx)
        #expect(report.errors.map(\.message) == ["xcodebuild failed (exit 74) without reporting an error; the log's last lines follow"])
        #expect(report.logTail == ["line one", "line two"])
        #expect(report.text.contains("\n  line one\n  line two\n"))
    }

    @Test func timeoutErrorNamesTheLog() async throws {
        defer { worktree.remove() }
        _ = try setUp()
        fake.stub(["xcrun", "xcodebuild", "build"]) { _ in throw XcdError(.timeout, "`xcrun xcodebuild build` timed out") }
        var ctx = try context()
        let error = await #expect(throws: XcdError.self) { try await service().build(BuildOptions(device: "mac"), in: &ctx) }
        #expect(error?.code == .timeout)
        #expect(error?.details.last?.hasPrefix("log: \(dir)/.xcdev/logs/") == true)
    }

    @Test func cleanRunsXcodebuildCleanWithoutCloningAndForgetsBuilds() async throws {
        defer { worktree.remove() }
        let (sims, xcodebuild) = try setUp()
        var ctx = try context()
        try AppStateStore.save(AppState(builds: ["iphone": BuildRecord(scheme: "App", configuration: nil, product: nil,
                                                                        finishedAt: Date())]), ctx.paths)
        let report = try await service().clean(scheme: nil, deep: false, in: &ctx)
        let run = try #require(xcodebuild.runs.first)
        #expect(run.arguments.starts(with: ["xcodebuild", "clean", "-project"]))
        #expect(!run.arguments.contains("-destination"))
        #expect(sims.cloneCount == 0)
        #expect(report.text == "cleaned scheme=App\nlog: \(report.log ?? "")")
        #expect(try AppStateStore.load(ctx.paths).builds.isEmpty)
    }

    @Test func deepCleanDeletesDerivedData() async throws {
        defer { worktree.remove() }
        _ = try setUp()
        var ctx = try context()
        try FileManager.default.createDirectory(atPath: ctx.paths.derivedData + "/Build", withIntermediateDirectories: true)
        let report = try await service().clean(scheme: nil, deep: true, in: &ctx)
        #expect(!FileManager.default.fileExists(atPath: ctx.paths.derivedData))
        #expect(report.text == "removed \(ctx.paths.derivedData)")
        let again = try await service().clean(scheme: nil, deep: true, in: &ctx)
        #expect(again.text == "nothing to remove; \(ctx.paths.derivedData) does not exist")
    }

    @Test func failedReportText() {
        let report = BuildReport(
            succeeded: false, scheme: "App", target: "iphone", targetSummary: "iphone (iPhone 18 Pro, iOS 27.0)",
            seconds: 12.44, errors: [Diagnostic(.error, "cannot find 'authModel' in scope", file: "/w/Login.swift", line: 42, column: 13)],
            warningCount: 14, warnings: nil, product: nil, log: "/w/.xcdev/logs/20260930-211205-build.log",
            resultBundle: "/w/.xcdev/results/20260930-211205-build.xcresult", logTail: nil, worktree: "feat")
        #expect(Renderer.report(report, command: "build", format: .text) == """
        build failed  scheme=App device=iphone (iPhone 18 Pro, iOS 27.0)  12.4s
        /w/Login.swift:42:13: error: cannot find 'authModel' in scope
        1 error, 14 warnings (xcd build --warnings)
        log: /w/.xcdev/logs/20260930-211205-build.log
        next: fix the errors and re-run `xcd build`
        """)
    }

    @Test func succeededReportText() {
        let report = BuildReport(
            succeeded: true, scheme: "App", target: "iphone", targetSummary: "iphone (iPhone 18 Pro, iOS 27.0)",
            seconds: 3.0, errors: [], warningCount: 0, warnings: nil,
            product: AppProduct(path: "/w/DD/App.app", bundleId: "dev.x.App", executableName: "App", platform: "iphonesimulator"),
            log: "/w/b.log", resultBundle: nil, logTail: nil, worktree: "feat")
        #expect(report.text == """
        build succeeded  scheme=App device=iphone (iPhone 18 Pro, iOS 27.0)  3.0s
        app: /w/DD/App.app  bundle=dev.x.App
        log: /w/b.log
        """)
    }
}
