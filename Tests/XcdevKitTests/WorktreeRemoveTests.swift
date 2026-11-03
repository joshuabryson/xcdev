import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct WorktreeRemoveTests {
    let fake = FakeProcessRunner()

    func setup() async throws -> (TempProject, WorktreeService, WorktreeContext, WorktreeState) {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        let svc = WorktreeService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home))
        let main = try await svc.open(from: project.root)
        let (state, _) = try await svc.create(name: "feat", in: main)
        return (project, svc, main, state)
    }

    @Test func removesCheckoutClonesAndRegistryButKeepsBranch() async throws {
        let (project, svc, main, created) = try await setup()
        defer { project.remove() }
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        var state = created
        state.devices["iphone"] = ProvisionedDevice(udid: "4CEABB59-81A5-4060-9573-99D2BA1BA97B", deviceType: "iPhone 18 Pro",
                                                    deviceTypeIdentifier: "t", runtime: "iOS 27.0", runtimeIdentifier: "r")
        try WorktreeStateStore.save(state, WorktreePaths(root: state.path))

        let removal = try await svc.remove(name: "feat", in: main)
        #expect(removal.removedDevices == ["iphone"])
        #expect(!removal.stateMissing)
        #expect(sims.devices.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: state.path))
        #expect(try svc.list(projectRoot: project.root).map(\.name) == ["main"])
        try TempProject.git(["rev-parse", "--verify", "refs/heads/feat"], in: project.root)   // branch kept
    }

    @Test func removeReportsTheDiskItFreed() async throws {
        let (project, svc, main, created) = try await setup()
        defer { project.remove() }
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        var state = created
        state.devices["iphone"] = ProvisionedDevice(udid: "4CEABB59-81A5-4060-9573-99D2BA1BA97B", deviceType: "iPhone 18 Pro",
                                                    deviceTypeIdentifier: "t", runtime: "iOS 27.0", runtimeIdentifier: "r")
        try WorktreeStateStore.save(state, WorktreePaths(root: state.path))
        fake.stub(["du"]) { inv in
            let lines = inv.arguments.dropFirst().map { path in
                let kb = path.hasSuffix(".xcdev") ? 200 : 250
                return "\(kb)\t\(path)"
            }
            return ProcessOutput(stdout: lines.joined(separator: "\n") + "\n")
        }

        let removal = try await svc.remove(name: "feat", in: main)
        #expect(removal.checkoutBytes == Int64(51_200))
        #expect(removal.stateBytes == Int64(204_800))
        #expect(removal.cloneBytes == Int64(1_048_576))
        #expect(removal.text.contains("disk freed: 1.2MB (checkout 50KB, build state 200KB, simulators 1.0MB)"))
        #expect(!FileManager.default.fileExists(atPath: state.path))
        #expect(sims.devices.isEmpty)
        try TempProject.git(["rev-parse", "--verify", "refs/heads/feat"], in: project.root)
    }

    @Test func refusesDirtyWorktreeUnlessForced() async throws {
        let (project, svc, main, state) = try await setup()
        defer { project.remove() }
        try project.write("change", to: "README.md", in: state.path)
        let error = await #expect(throws: XcdError.self) { try await svc.remove(name: "feat", in: main) }
        #expect(error?.code == .worktreeDirty)
        #expect(error?.details == [" M README.md"])
        #expect(error?.next == "commit or stash them, or re-run `xcd wt remove feat --force`")
        #expect(FileManager.default.fileExists(atPath: state.path))

        _ = try await svc.remove(name: "feat", force: true, in: main)
        #expect(!FileManager.default.fileExists(atPath: state.path))
    }

    @Test func removeSucceedsWhenDirectoryIsAlreadyGone() async throws {
        let (project, svc, main, state) = try await setup()
        defer { project.remove() }
        try FileManager.default.removeItem(atPath: state.path)
        let removal = try await svc.remove(name: "feat", in: main)
        #expect(removal.stateMissing)
        #expect(removal.project == "Sample App")
        #expect(removal.text.contains("(named \"xcd · Sample App · feat · …\")"))
        #expect(try svc.list(projectRoot: project.root).map(\.name) == ["main"])
    }

    @Test func cannotRemoveMainOrUnknown() async throws {
        let (project, svc, main, _) = try await setup()
        defer { project.remove() }
        let mainError = await #expect(throws: XcdError.self) { try await svc.remove(name: "main", in: main) }
        #expect(mainError?.code == .usage)
        let unknown = await #expect(throws: XcdError.self) { try await svc.remove(name: "nope", in: main) }
        #expect(unknown?.code == .worktreeNotFound)
    }

    @Test func removeStopsTheWorktreesRecordings() async throws {
        let (project, _, ctx, state) = try await setup()
        defer { project.remove() }
        let id = ProcessIdentity(pid: 4343, startTime: 1, arguments: ["simctl", "recordVideo"])
        let detached = FakeDetachedProcesses()
        detached.adopt(id)
        let paths = WorktreePaths(root: state.path)
        try Recordings.save(RecordingRecord(device: "iphone", udid: "U", path: state.path + "/r.mp4", log: "/l",
                                            process: id, startedAt: Date()), to: paths.recordingFile(device: "iphone"))
        let svc = WorktreeService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home), detached: detached)
        let removal = try await svc.remove(name: state.name, force: true, in: ctx)
        #expect(detached.stops == [.init(pid: 4343, signal: SIGINT)])
        #expect(removal.stoppedRecordings.count == 1 && removal.text.contains("stopped the iphone recording"))
        #expect(removal.stoppedRunners.isEmpty)
    }

    @Test func removingAWorktreeEndsItsClonesWatchdogs() async throws {
        let (project, _, ctx, created) = try await setup()
        defer { project.remove() }
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        var state = created
        let udid = "4CEABB59-81A5-4060-9573-99D2BA1BA97B"
        state.devices["iphone"] = ProvisionedDevice(udid: udid, deviceType: "iPhone 18 Pro", deviceTypeIdentifier: "t",
                                                    runtime: "iOS 27.0", runtimeIdentifier: "r")
        try WorktreeStateStore.save(state, WorktreePaths(root: state.path))
        let detached = FakeDetachedProcesses()
        let holds = LeaseHolds()
        let globalPaths = GlobalPaths(base: project.home)
        let leases = DeviceLeases(globalPaths: globalPaths, holds: holds)
        try leases.save(.sample(udid: udid))
        try await Watchdogs(leases: leases, detached: detached).start(udid, developerDir: nil, log: "/l", executable: "/xcd")
        let pid = try #require(detached.starts.first).identity.pid

        let svc = WorktreeService(runner: RoutingRunner(fake: fake), globalPaths: globalPaths, detached: detached)
        _ = try await svc.remove(name: state.name, force: true, in: ctx)
        #expect(detached.stops.contains { $0.pid == pid && $0.signal == SIGTERM })
        #expect(leases.load(udid) == nil)
        holds.release(udid)
    }

    @Test func removeStopsTheWorktreesUIRunner() async throws {
        let (project, _, ctx, state) = try await setup()
        defer { project.remove() }
        let id = ProcessIdentity(pid: 5252, startTime: 1, arguments: ["xcodebuild", "test-without-building"])
        let detached = FakeDetachedProcesses()
        detached.adopt(id)
        let paths = WorktreePaths(root: state.path)
        try Runners.save(RunnerRecord(device: "iphone", udid: "U", process: id, token: "t", port: 1, runnerKey: "k", log: "/l",
                                      readyFile: "/r", startedAt: Date(), restarts: [], failed: false),
                         to: paths.runnerFile(device: "iphone"))
        let svc = WorktreeService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home), detached: detached)
        let removal = try await svc.remove(name: state.name, force: true, in: ctx)
        #expect(detached.stops == [.init(pid: 5252, signal: SIGTERM)])
        #expect(removal.stoppedRunners == ["stopped the iphone UI runner"] && removal.stoppedRecordings.isEmpty)
        #expect(removal.text.contains("\nstopped the iphone UI runner"))
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(removal)) as? [String: Any])
        #expect(json["stoppedRunners"] as? [String] == ["stopped the iphone UI runner"] && json["stoppedRecordings"] as? [String] == [])
    }
}
