import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// What the doctor suites share: a fake simulator on `fake`, a project with its main worktree registered, git run
/// for real, and doctor on both.
protocol DoctorFixture {
    var fake: FakeProcessRunner { get }
}

extension DoctorFixture {
    /// A project with its main worktree registered, simulators from the simctl-list fixture (no xcd devices yet),
    /// and git run for real.
    func setup(config: String = WorktreeServiceTests.config) async throws -> (TempProject, FakeSimulators, WorktreeService, WorktreeContext) {
        let project = try TempProject.make(config: config)
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        let worktrees = WorktreeService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                                        detached: FakeDetachedProcesses())
        return (project, sims, worktrees, try await worktrees.open(from: project.root))
    }

    /// Doctor on the project, launching nothing real: a fix that starts a watchdog starts "/xcd" on a fake.
    func doctor(_ project: TempProject, discovery: XcodeDiscovery? = nil,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in /* doctor's pauses are skipped */ }) -> DoctorService {
        DoctorService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                      discovery: discovery ?? XcodeDiscovery(runner: fake, applicationsDirectories: []),
                      detached: FakeDetachedProcesses(), accessibility: { FakeAccessibility(app: FakeApp(windows: [])) },
                      hostApp: { "TestHost" }, xcdExecutable: "/xcd", sleep: sleep)
    }

    /// Registers worktree `name` of the project at `root` (named after its folder) at `path`, as `xcd wt create` does.
    func register(_ name: String, of root: String, at path: String, home: String) async throws {
        let state = WorktreeState(id: UUID().uuidString, name: name, project: (root as NSString).lastPathComponent, projectRoot: root,
                                  path: path, branch: name, xcode: nil, devices: [:], status: .ready, createdAt: Date())
        try await Registry(paths: GlobalPaths(base: home)).upsert(RegistryEntry(state))
    }

    /// A CoreSimulator that fails `simctl list` until `pkill` restarts it. Returns the count of restarts.
    func coreSimulatorThatAnswersOnceRestarted() -> Counter {
        let listing = Fixture.string("simctl-list.json")
        let restarted = Counter()
        fake.stub(["xcrun", "simctl", "list", "-j"]) { _ in
            restarted.value == 0 ? ProcessOutput(exitCode: 1, stderr: "Failed to initialize simulator device set.")
                                 : ProcessOutput(stdout: listing)
        }
        fake.stub(["pkill"]) { _ in restarted.increment(); return ProcessOutput() }
        return restarted
    }

    /// Records `udid` as the worktree's clone of `device`.
    func record(_ udid: String, as device: String, in ctx: inout WorktreeContext) throws {
        ctx.state.devices[device] = ProvisionedDevice(udid: udid, deviceType: "iPhone 18 Pro", deviceTypeIdentifier: "t",
                                                      runtime: "iOS 27.0", runtimeIdentifier: "r")
        try WorktreeStateStore.save(ctx.state, ctx.paths)
    }

    var pkillCalls: Int { fake.calls.filter { $0.argv.first == "pkill" }.count }

    /// Makes `path`'s folder look created `seconds` ago, and returns a dataPath inside it.
    func agedDevice(_ path: String, seconds: TimeInterval) throws -> String {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: path)
        return path + "/data"
    }

    /// What `xcd wt create <name>` leaves after `git worktree add`, whether it was killed there or is still running
    /// its post-worktree-create hook: an incomplete entry, checkout, and state. Returns the checkout's path.
    func halfCreated(_ name: String, in project: TempProject) async throws -> String {
        let path = project.base + "/Sample App.worktrees/" + name
        try TempProject.git(["worktree", "add", "-b", name, path, "HEAD"], in: project.root)
        let state = WorktreeState(id: name + "-id", name: name, project: "Sample App", projectRoot: project.root,
                                  path: Paths.canonical(path), branch: name, xcode: nil, devices: [:], status: .incomplete,
                                  createdAt: Date())
        try WorktreeStateStore.save(state, WorktreePaths(root: state.path))
        try await Registry(paths: GlobalPaths(base: project.home)).upsert(RegistryEntry(state))
        return path
    }

    /// Holds the lock at `path`, as another xcd's `wt create` or `wt remove` would, from before this returns until
    /// `letGo`, or until anything in this process waits for the lock. Doctor must never wait for it: one that did
    /// would get the lock at once and fail the test at `letGo`, rather than hang it.
    func holdLock(_ path: String) async throws -> HeldLock {
        let (acquired, signal) = AsyncStream<Void>.makeStream()
        let holder = Task {
            defer { signal.finish() }
            return try await FileLock.withLock(at: path) {
                signal.yield()
                while !Task.isCancelled {
                    if FileLock.isAwaited(at: path) { return true }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                return false
            }
        }
        for await _ in acquired { break }
        return HeldLock(holder: holder)
    }
}

/// A lock a test holds as another xcd would: see `DoctorFixture.holdLock`.
struct HeldLock {
    /// Ends saying whether anything waited for the lock.
    let holder: Task<Bool, any Error>

    /// Lets go of the lock, and fails the test if anything waited for it meanwhile.
    func letGo(sourceLocation: SourceLocation = #_sourceLocation) async {
        holder.cancel()
        let waited = (try? await holder.value) ?? false
        #expect(!waited, "something waited for a lock that another xcd holds", sourceLocation: sourceLocation)
    }
}

extension DoctorProblem {
    /// The problem as doctor reports it when run in the project whose main checkout is `root`: that project's.
    func inProject(_ root: String) -> DoctorProblem {
        var problem = self
        problem.scope = .project
        problem.projectRoot = root
        return problem
    }
}

/// The doctor fixture never launches a real process: a fix starts a clone's watchdog, and removing a worktree stops
/// its recordings, runners, and watchdogs.
@Suite struct DoctorFixtureTests: DoctorFixture {
    let fake = FakeProcessRunner()

    @Test func theFixtureLaunchesThroughAFake() async throws {
        let (project, _, worktrees, _) = try await setup()
        defer { project.remove() }
        let service = doctor(project)
        #expect(service.detached is FakeDetachedProcesses)
        #expect(service.xcdExecutable == "/xcd")
        #expect(worktrees.detached is FakeDetachedProcesses)
    }
}
