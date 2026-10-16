import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

extension FakeProcessRunner {
    /// A project with its main worktree registered, git run for real, and no xcd clones.
    func doctorProject() async throws -> (TempProject, WorktreeContext) {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        _ = try FakeSimulators(runner: self, catalogJSON: Fixture.string("simctl-list.json"))
        let worktrees = WorktreeService(runner: RoutingRunner(fake: self), globalPaths: GlobalPaths(base: project.home))
        return (project, try await worktrees.open(from: project.root))
    }
}

@Suite struct RunnersCheckTests {
    let fake = FakeProcessRunner()

    func setup() async throws -> (TempProject, WorktreeContext) { try await fake.doctorProject() }

    func runnerRecord(_ device: String, pid: Int32, in ctx: WorktreeContext) throws -> ProcessIdentity {
        let id = ProcessIdentity(pid: pid, startTime: 1, arguments: ["xcodebuild", "test-without-building"])
        try Runners.save(RunnerRecord(device: device, udid: "U", process: id, token: "t", port: 40000 + Int(pid), runnerKey: "k",
                                      log: "/l", readyFile: "/r", startedAt: Date(), restarts: [],
                                      failed: false), to: ctx.paths.runnerFile(device: device))
        return id
    }

    @Test func runnersThatEndedOrStoppedAnsweringAreFixedHealthyOnesAreLeftAlone() async throws {
        let (project, ctx) = try await setup()
        defer { project.remove() }
        let detached = FakeDetachedProcesses()
        _ = try runnerRecord("ended", pid: 11, in: ctx)                                  // process gone
        detached.adopt(try runnerRecord("deaf", pid: 12, in: ctx))                       // xcodebuild alive, runner dead
        detached.adopt(try runnerRecord("fine", pid: 13, in: ctx))
        // Only the "fine" runner (port 40013) answers.
        let client = RunnerClient(transport: PortTransport(healthyPort: 40013, healthy: FakeRunnerTransport()))
        let service = DoctorService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                                    discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []), detached: detached,
                                    runnerClient: client)
        let report = await service.run(fix: false, from: nil)
        let check = try #require(report.checks.first { $0.id == "ui-runners" })
        #expect(check.problems.map(\.action) == [.stopRunner, .forgetRunner])            // deaf, ended (sorted by file name)
        #expect(check.problems.allSatisfy { $0.projectRoot == ctx.location.projectRoot })
        #expect(detached.stops.isEmpty)
        let fixed = await service.run(fix: true, from: nil)
        #expect(fixed.checks.first { $0.id == "ui-runners" }?.problems.allSatisfy(\.fixed) == true)
        #expect(detached.stops == [.init(pid: 12, signal: SIGTERM)])
        #expect(ctx.paths.runnerFiles == [ctx.paths.runnerFile(device: "fine")])
    }

    /// Answers `/health` only on one port.
    struct PortTransport: RunnerTransport {
        let healthyPort: Int
        let healthy: FakeRunnerTransport
        func send(to endpoint: RunnerEndpoint, path: String, body: Data?, timeout: Duration) async throws -> (status: Int, body: Data) {
            guard endpoint.port == healthyPort else { throw RunnerUnreachable(reason: "refused") }
            return try await healthy.send(to: endpoint, path: path, body: body, timeout: timeout)
        }
    }

    @Test func aRunnerBeingStartedByAnotherXcdIsLeftAlone() async throws {
        let (project, ctx) = try await setup()
        defer { project.remove() }
        _ = try runnerRecord("starting", pid: 21, in: ctx)                               // process gone, but its lock is held
        let globalPaths = GlobalPaths(base: project.home)
        let service = DoctorService(runner: RoutingRunner(fake: fake), globalPaths: globalPaths,
                                    discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []),
                                    detached: FakeDetachedProcesses())
        let lock = Runners.lockPath(globalPaths: globalPaths, worktreeRoot: ctx.paths.root, device: "starting")
        let check = try await FileLock.withLock(at: lock) {
            await service.run(fix: true, from: nil).checks.first { $0.id == "ui-runners" }
        }
        #expect(check?.problems.isEmpty == true)
        #expect(check?.inProgress == ["\(ctx.state.project)/\(ctx.state.name)'s starting UI runner is being started by another xcd; left alone"])
        #expect(ctx.paths.runnerFiles == [ctx.paths.runnerFile(device: "starting")])
    }

    @Test func aRunnerStartedBetweenDetectAndFixIsNeitherStoppedNorForgotten() async throws {
        let (project, ctx) = try await setup()
        defer { project.remove() }
        let detached = FakeDetachedProcesses()
        detached.adopt(try runnerRecord("deaf", pid: 12, in: ctx))
        let globalPaths = GlobalPaths(base: project.home)
        let service = DoctorService(runner: RoutingRunner(fake: fake), globalPaths: globalPaths,
                                    discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []), detached: detached,
                                    runnerClient: RunnerClient(transport: PortTransport(healthyPort: 0, healthy: FakeRunnerTransport())))
        let env = await service.environment(from: nil, fixing: true)
        let problem = try #require(await StaleUIRunnersCheck().detect(env).first)
        #expect(problem.action == .stopRunner)

        // Another xcd takes the runner's lock after doctor looked, to start a runner.
        let lock = Runners.lockPath(globalPaths: globalPaths, worktreeRoot: ctx.paths.root, device: "deaf")
        let outcome: DoctorLeftAlone? = try await FileLock.withLock(at: lock) {
            do {
                try await StaleUIRunnersCheck().fix(problem, env)
                return nil
            } catch let left as DoctorLeftAlone {
                return left
            }
        }
        #expect(outcome?.note == "the deaf UI runner is being started by another xcd; left alone")
        #expect(detached.stops.isEmpty)
        #expect(ctx.paths.runnerFiles == [ctx.paths.runnerFile(device: "deaf")])
    }
}
