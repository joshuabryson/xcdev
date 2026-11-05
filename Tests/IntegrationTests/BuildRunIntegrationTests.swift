import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"

@Suite(.enabled(if: enabled, "set XCD_INTEGRATION=1 to run (needs Xcode + an iOS simulator runtime)"), .serialized)
struct BuildRunIntegrationTests {
    let runner = SystemProcessRunner()

    func iPhoneType() async throws -> String {
        try await firstIPhoneType(runner).name
    }

    func appProject() async throws -> TempProject {
        try TempProject.make(config: """
        version: 1
        project: SampleApp.xcodeproj
        schemes: { app: SampleApp, test: SampleApp }
        defaultDevice: iphone
        devices:
          iphone: { type: "\(try await iPhoneType())" }
        """, name: "Sample App \(UUID().uuidString.prefix(6))", fixture: repoRoot + "/Fixtures/SampleApp", parent: testsHome)
    }

    /// Runs `body` in the main worktree (main can't be removed), then cleans up as `withCleanup` does.
    func inMainWorktree(_ project: TempProject,
                        _ body: (inout WorktreeContext, Services) async throws -> Void) async throws {
        try await withCleanup(project) { svc in
            var ctx = try await svc.open(worktree: nil)
            try await body(&ctx, svc)
        }
    }

    @Test func buildRunLogsAndTerminate() async throws {
        try await inMainWorktree(try await appProject()) { ctx, svc in
            let build = try await svc.builds.build(BuildOptions(), in: &ctx)
            #expect(build.succeeded, "\(build.text)")
            let product = try #require(build.product)
            #expect(product.bundleId == "dev.xcdev.SampleApp")
            #expect(product.path.hasPrefix(ctx.paths.derivedData))

            let run = try await svc.apps.run(BuildOptions(), noBuild: true,
                                             launch: LaunchOptions(environment: ["GREETING": "hi"]), in: &ctx)
            #expect(run.status == .running, "\(run.text)")
            #expect(run.note == nil)
            let appLog = try #require(run.appLog)
            #expect(try String(contentsOfFile: appLog, encoding: .utf8).contains("SampleApp launched greeting=hi"))

            var found = false
            for _ in 0..<10 where !found {             // the unified log can lag a few seconds
                let logs = try await svc.logs.logs(LogOptions(since: .seconds(300)), in: &ctx)
                found = logs.entries.contains { $0.message == "sample log line" }
                if !found { try await Task.sleep(for: .seconds(1)) }
            }
            #expect(found)
            let streamed = try await svc.logs.logs(LogOptions(follow: .seconds(3)), in: &ctx)
            #expect(streamed.file != nil)
            let output = try await svc.logs.logs(LogOptions(appOutput: true), in: &ctx)
            #expect(output.lines.contains("SampleApp launched greeting=hi"))
            #expect(try await svc.apps.terminate(device: nil, in: &ctx).action == "terminated")
        }
    }

    @Test func testsReportFailuresFiltersAndEmptyMatches() async throws {
        try await inMainWorktree(try await appProject()) { ctx, svc in
            let all = try await svc.tests.test(TestOptions(), in: &ctx)
            #expect(all.outcome == .failed, "\(all.text)")
            #expect(all.counts == TestCounts(total: 4, passed: 2, failed: 1, skipped: 1, expectedFailures: 0))
            let failure = try #require(all.failures.first)
            #expect(failure.test == "SampleAppTests/failsOnPurpose()")
            #expect(failure.file?.hasSuffix("SampleAppTests/SampleAppTests.swift") == true && failure.line == 9,
                    "\(failure.file ?? "no file"):\(failure.line.map(String.init) ?? "no line")")

            let only = try await svc.tests.test(TestOptions(only: ["SampleAppTests/passes()"]), in: &ctx)
            #expect(only.outcome == .passed && only.counts.passed == 1, "\(only.text)")

            let none = try await svc.tests.test(TestOptions(only: ["SampleAppTests/passes"]), in: &ctx)
            #expect(none.outcome == .noTests, "\(none.text)")
        }
    }

    @Test func aCrashIsReportedWithTheFatalError() async throws {
        try await inMainWorktree(try await appProject()) { ctx, svc in
            let run = try await svc.apps.run(BuildOptions(), noBuild: false,
                                             launch: LaunchOptions(arguments: ["-crashOnLaunch"]), in: &ctx)
            #expect(run.status == .crashed, "\(run.text)")
            #expect(run.failure?.code == .appCrashed)
            #expect(run.crash?.pid == run.pid)
            #expect(run.crash?.frames.contains { $0.contains("SampleAppApp.init()") } == true)
            #expect(run.appOutput?.contains { $0.contains("Fatal error: SampleApp crashed on purpose") } == true)
            if let report = run.crash?.path { try? FileManager.default.removeItem(atPath: report) }
        }
    }

    @Test func aBrokenBuildReportsEveryFilesErrors() async throws {
        let project = try await appProject()
        try project.write("""
        struct BrokenAuth {
            func currentUser() -> String {
                return authModel.userName
            }
        }
        """, to: "SampleApp/BrokenAuth.swift")
        try project.write("""
        func brokenDouble(_ value: Int) -> Int {
            let factor: Int = "two"
            return value * factor
        }
        """, to: "SampleApp/BrokenMath.swift")
        try await inMainWorktree(project) { ctx, svc in
            let build = try await svc.builds.build(BuildOptions(), in: &ctx)
            #expect(build.failure?.code == .buildFailed)
            let texts = build.errors.map(\.text)
            #expect(texts.contains { $0.hasSuffix("SampleApp/BrokenAuth.swift:3:16: error: Cannot find 'authModel' in scope") }, "\(build.text)")
            #expect(texts.contains { $0.hasSuffix("SampleApp/BrokenMath.swift:2:23: error: Cannot convert value of type 'String' to specified type 'Int'") }, "\(build.text)")
        }
    }

    @Test func aPackageBuildsAndTestsOnTheHost() async throws {
        let project = try TempProject.make(config: "version: 1\nproject: Package.swift\n",
                                           name: "Sample Package \(UUID().uuidString.prefix(6))",
                                           fixture: repoRoot + "/Fixtures/SamplePackage", parent: testsHome)
        try await inMainWorktree(project) { ctx, svc in
            let build = try await svc.builds.build(BuildOptions(), in: &ctx)
            #expect(build.succeeded && build.target == "host" && build.product == nil, "\(build.text)")
            let tests = try await svc.tests.test(TestOptions(), in: &ctx)
            #expect(tests.outcome == .passed && tests.counts.passed == 1, "\(tests.text)")
            #expect(ctx.state.devices.isEmpty)
        }
    }

    @Test func twoWorktreesBuildAndRunAtTheSameTime() async throws {
        try await withCleanup(try await appProject()) { svc in
            let main = try await svc.open(worktree: nil)
            var failure: (any Error)?
            do {
                let a = try await svc.worktrees.create(name: "agent-a", in: main).state
                let b = try await svc.worktrees.create(name: "agent-b", in: main).state

                @Sendable func build(_ path: String) async throws -> (BuildReport, WorktreeContext) {
                    var ctx = try await svc.worktrees.open(from: path)
                    let report = try await svc.builds.build(BuildOptions(), in: &ctx)
                    return (report, ctx)
                }
                async let first = build(a.path)
                async let second = build(b.path)
                let ((reportA, ctxA), (reportB, ctxB)) = try await (first, second)
                #expect(reportA.succeeded && reportB.succeeded, "\(reportA.text)\n\(reportB.text)")
                #expect(reportA.product?.path.hasPrefix(ctxA.paths.derivedData) == true)
                #expect(reportB.product?.path.hasPrefix(ctxB.paths.derivedData) == true)
                let udidA = try #require(ctxA.state.devices["iphone"]?.udid)
                let udidB = try #require(ctxB.state.devices["iphone"]?.udid)
                #expect(udidA != udidB)

                @Sendable func launch(_ path: String) async throws -> RunReport {
                    var ctx = try await svc.worktrees.open(from: path)
                    return try await svc.apps.run(BuildOptions(), noBuild: true, launch: LaunchOptions(), in: &ctx)
                }
                async let runA = launch(a.path)
                async let runB = launch(b.path)
                let (launchedA, launchedB) = try await (runA, runB)
                #expect(launchedA.status == .running && launchedB.status == .running,
                        "\(launchedA.text)\n\(launchedB.text)")
                #expect(launchedA.pid != launchedB.pid)

                _ = try await svc.worktrees.remove(name: "agent-a", in: main)
                _ = try await svc.worktrees.remove(name: "agent-b", in: main)
            } catch { failure = error }
            // A failed step skips the removals above; remove through xcd anyway (withCleanup then sweeps clones).
            if let failure {
                for name in ["agent-a", "agent-b"] { _ = try? await svc.worktrees.remove(name: name, force: true, in: main) }
                throw failure
            }
        }
    }
}
