import Foundation
import Synchronization
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct ProjectCommandTests {
    let worktree = FakeWorktree(prefix: "xcd command")
    var fake: FakeProcessRunner { worktree.runner }

    func context(_ commands: String) throws -> WorktreeContext {
        try worktree.context(BuildServiceTests.config + "\ncommands:\n" + commands, container: "App.xcodeproj")
    }

    func runner(environment: [String: String] = [:]) -> ProjectCommandRunner {
        ProjectCommandRunner(builds: BuildService(runner: fake, provisioner: worktree.provisioner), output: .json,
                             environment: environment)
    }

    /// The command's own process is `sh`; record it and exit with `code`.
    func stubShell(exit code: Int32 = 0) {
        fake.stub(["sh"]) { _ in ProcessOutput(exitCode: code) }
    }

    var shellCall: Invocation? { fake.calls.first { $0.argv.first == "sh" } }

    @Test func passesArgumentsContextAndExitCodeThrough() async throws {
        defer { worktree.remove() }
        stubShell(exit: 3)
        var ctx = try context("  seed-db: { run: ./scripts/seed.sh, timeout: 10m }")
        let code = try await runner().run("seed-db", arguments: ["a b", "--flag"], in: &ctx)
        #expect(code == 3)
        let call = try #require(shellCall)
        #expect(call.arguments == ["-c", "./scripts/seed.sh \"$@\"", "xcd-seed-db", "a b", "--flag"])
        #expect(call.passthrough && call.workingDirectory == worktree.root && call.timeout == .seconds(600))
        #expect(call.environment["XCD_WORKTREE_NAME"] == "feat")
        #expect(call.environment["XCD_DEVICE"] == "iphone")          // defaultDevice, not cloned
        #expect(call.environment["XCD_UDID"] == nil)
        #expect(call.environment["XCD_OUTPUT"] == "json")
        #expect(!fake.calls.contains { $0.arguments.starts(with: ["simctl", "clone"]) })
    }

    @Test func aBorrowedCommandWhoseScriptIsMissingSaysWhereTheCommandComesFrom() async throws {
        defer { worktree.remove() }
        stubShell(exit: 127)
        let lines = Mutex<[String]>([])
        let runner = ProjectCommandRunner(builds: BuildService(runner: fake, provisioner: worktree.provisioner,
                                                               progress: { line in lines.withLock { $0.append(line) } }))
        var ctx = try context("  seed: { run: ./scripts/seed.sh }")
        ctx.borrowedConfig = "/p/.xcdev.yml"
        #expect(try await runner.run("seed", arguments: [], in: &ctx) == 127)
        #expect(lines.withLock { $0 } == ["`xcd seed` exited 127: its command was not found; check commands.seed.run in .xcdev.yml; "
            + "the command comes from the main checkout's .xcdev.yml (/p/.xcdev.yml), and its script may not be on this branch; "
            + "ask the user before changing that file"])
        runner.explain(126, of: "seed", borrowedConfig: "/p/.xcdev.yml")
        runner.explain(127, of: "seed", borrowedConfig: nil)
        runner.explain(126, of: "seed", borrowedConfig: nil)
        #expect(lines.withLock { $0 }.suffix(3) == [
            "`xcd seed` exited 126: its script is not executable; run `chmod +x` on it; the command comes from the main checkout's .xcdev.yml (/p/.xcdev.yml)",
            "`xcd seed` exited 127: its command was not found; check commands.seed.run in .xcdev.yml",
            "`xcd seed` exited 126: its script is not executable; run `chmod +x` on it",
        ])
    }

    /// The same runner, with the command's shell a real /bin/sh.
    func realShell() -> ProjectCommandRunner {
        let routing = RoutingRunner(fake: fake, realExecutables: ["sh"])
        return ProjectCommandRunner(builds: BuildService(runner: routing, provisioner: worktree.provisioner), output: .json)
    }

    /// A `run` written as a YAML block ends in a newline. With the arguments on a line of their own, an empty
    /// argument list would be an empty command, and its exit 0 the result.
    @Test func aRunWrittenAsABlockKeepsItsScriptsExitCode() async throws {
        defer { worktree.remove() }
        var ctx = try context("  check:\n    run: |\n      false\n")
        #expect(ctx.config.commands?["check"]?.run == "false\n")
        #expect(try await realShell().run("check", arguments: [], in: &ctx) == 1)
    }

    @Test func aRunWrittenAsABlockGetsItsArgumentsOnItsLastLine() async throws {
        defer { worktree.remove() }
        var ctx = try context("  show:\n    run: |\n      true\n      printf '[%s]\\n' >seen\n\n")
        #expect(try await realShell().run("show", arguments: ["a b", "--flag"], in: &ctx) == 0)
        #expect(try String(contentsOfFile: worktree.root + "/seen", encoding: .utf8) == "[a b]\n[--flag]\n")
    }

    /// After a `;` the arguments would be a command of their own, and with none its exit code would be the result.
    @Test func aRunEndedByASemicolonKeepsItsScriptsExitCode() async throws {
        defer { worktree.remove() }
        var ctx = try context("  ended: { run: \"false;\" }\n  spaced: { run: \"false ; \" }")
        #expect(try await realShell().run("ended", arguments: [], in: &ctx) == 1)
        #expect(try await realShell().run("spaced", arguments: [], in: &ctx) == 1)
    }

    /// A `;` after a backslash is an argument of the command, as in `find … -exec … \;`, so it is not the command's end.
    @Test func anEscapedSemicolonAtTheEndOfARunStaysAnArgument() async throws {
        #expect(ProjectCommandRunner.script(#"printf '[%s]\n' a\;"#) == #"printf '[%s]\n' a\; "$@""#)
        // Two backslashes are a backslash, so the `;` after them does end the command.
        #expect(ProjectCommandRunner.script(#"printf '[%s]\n' a\\;"#) == #"printf '[%s]\n' a\\ "$@""#)
    }

    @Test func needsDeviceClonesAndBootsItFirst() async throws {
        defer { worktree.remove() }
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        stubShell()
        var ctx = try context("  seed-db: { run: ./scripts/seed.sh, needs: [device] }")
        _ = try await runner().run("seed-db", arguments: [], in: &ctx)
        let udid = try #require(ctx.state.devices["iphone"]?.udid)
        #expect(sims.devices.first { $0.udid == udid }?.state == "Booted")
        #expect(shellCall?.environment["XCD_UDID"] == udid)
    }

    @Test func xcdDeviceChoosesTheDevice() async throws {
        defer { worktree.remove() }
        stubShell()
        var ctx = try context("  open-mac: { run: open ., needs: [device] }")
        _ = try await runner(environment: ["XCD_DEVICE": "mac"]).run("open-mac", arguments: [], in: &ctx)
        #expect(shellCall?.environment["XCD_DEVICE"] == "mac")
        #expect(!fake.calls.contains { $0.arguments.starts(with: ["simctl"]) })     // a Mac has nothing to boot
    }

    @Test func needsBuildBuildsOnlyWhenThereIsNoBuild() async throws {
        defer { worktree.remove() }
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        let xcodebuild = FakeXcodebuild(runner: fake)
        xcodebuild.onRun(.init(buildResults: Fixture.string("build-results-succeeded.json")))
        xcodebuild.onBuildSettings(Fixture.string("build-settings.json"))
        stubShell()
        var ctx = try context("  screenshot: { run: ./shot.sh, needs: [build] }")
        _ = try await runner().run("screenshot", arguments: [], in: &ctx)
        #expect(xcodebuild.runs.count == 1)
        #expect(shellCall?.environment["XCD_APP_PATH"]?.hasSuffix("SampleApp.app") == true)
        _ = try await runner().run("screenshot", arguments: [], in: &ctx)
        #expect(xcodebuild.runs.count == 1)                       // the recorded build is reused
    }

    @Test func aFailedBuildStopsTheCommand() async throws {
        defer { worktree.remove() }
        let xcodebuild = FakeXcodebuild(runner: fake)
        xcodebuild.onRun(.init(exitCode: 65, buildResults: Fixture.string("build-results-failed.json")))
        stubShell()
        var ctx = try context("  screenshot: { run: ./shot.sh, needs: [build] }")
        let error = await #expect(throws: XcdError.self) {
            try await runner(environment: ["XCD_DEVICE": "mac"]).run("screenshot", arguments: [], in: &ctx)
        }
        #expect(error?.code == .buildFailed)
        #expect(error?.message == "`xcd screenshot` needs a build, and the build failed with 2 errors")
        #expect(error?.details.last?.hasPrefix("log: ") == true)
        #expect(shellCall == nil)
    }

    @Test func aTimeoutPointsAtTheCommandsTimeoutKey() async throws {
        defer { worktree.remove() }
        fake.stub(["sh"]) { _ in
            throw XcdError(.timeout, "`/bin/sh -c ./seed.sh` timed out after 600 seconds", next: "re-run with a larger --timeout")
        }
        var ctx = try context("  seed-db: { run: ./seed.sh, timeout: 10m }")
        let error = await #expect(throws: XcdError.self) { try await runner().run("seed-db", arguments: [], in: &ctx) }
        #expect(error?.code == .timeout)
        #expect(error?.message == "`xcd seed-db` timed out after 10m00s")
        #expect(error?.next == "make it finish sooner, or raise commands.seed-db.timeout in .xcdev.yml, then re-run")
    }

    @Test func needsDeviceWithoutDevicesSaysWhatToAdd() async throws {
        defer { worktree.remove() }
        var ctx = try worktree.context("version: 1\nproject: Package.swift\ncommands:\n  seed: { run: x, needs: [device] }",
                                       container: "Package.swift")
        let error = await #expect(throws: XcdError.self) { try await runner().run("seed", arguments: [], in: &ctx) }
        #expect(error?.message == "`xcd seed` needs a device, but .xcdev.yml has no devices")
    }
}
