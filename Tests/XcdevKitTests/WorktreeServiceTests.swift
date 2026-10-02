import Foundation
import Synchronization
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct WorktreeServiceTests {
    static let config = """
    version: 1
    project: App.xcodeproj
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro" }
    """

    let fake = FakeProcessRunner()

    func service(_ project: TempProject) -> WorktreeService {
        WorktreeService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home))
    }

    @Test func locateOutsideGitFails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("not-git-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let error = await #expect(throws: XcdError.self) {
            try await WorktreeLocator(runner: SystemProcessRunner()).locate(from: dir)
        }
        #expect(error?.code == .notInProject)
        #expect(error?.next != nil)
    }

    @Test func openWithoutConfigFails() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        try FileManager.default.removeItem(atPath: project.root + "/.xcdev.yml")
        let error = await #expect(throws: XcdError.self) { try await service(project).open(from: project.root) }
        #expect(error?.code == .configMissing)
    }

    @Test func openMainInitializesStateAndRegistry() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let ctx = try await service(project).open(from: project.root + "/")
        #expect(ctx.location.isMain)
        #expect(ctx.location.projectName == "Sample App")
        #expect(ctx.state.name == "main")
        #expect(ctx.state.branch == "main")
        #expect(FileManager.default.fileExists(atPath: project.root + "/.xcdev/worktree.json"))
        #expect(try service(project).list(projectRoot: project.root).map(\.name) == ["main"])

        let again = try await service(project).open(from: project.root)
        #expect(again.state.id == ctx.state.id)                    // stable across calls
    }

    @Test func createAddsWorktreeBranchAndState() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let svc = service(project)
        let main = try await svc.open(from: project.root)
        let (state, created) = try await svc.create(name: "login-flow", in: main)

        #expect(created)
        #expect(state.status == .ready)
        #expect(state.branch == "login-flow")
        #expect(state.path == Paths.canonical(project.base + "/Sample App.worktrees/login-flow"))
        #expect(state.devices.isEmpty)                              // cloning is lazy
        #expect(FileManager.default.fileExists(atPath: state.path + "/README.md"))
        #expect(fake.calls.isEmpty)                                 // no simctl calls at all

        let opened = try await svc.open(from: state.path)
        #expect(opened.state.id == state.id)
        #expect(!opened.location.isMain)
        #expect(opened.location.projectRoot == project.root)
        #expect(try svc.list(projectRoot: project.root).map(\.name) == ["login-flow", "main"])
    }

    @Test func createIsIdempotent() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let svc = service(project)
        let main = try await svc.open(from: project.root)
        let first = try await svc.create(name: "feat", in: main)
        let second = try await svc.create(name: "feat", in: main)
        #expect(!second.created)
        #expect(second.state.id == first.state.id)
    }

    @Test func createFromRefAndExistingBranch() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        try TempProject.git(["branch", "existing"], in: project.root)
        let svc = service(project)
        let main = try await svc.open(from: project.root)
        let fromExisting = try await svc.create(name: "existing", in: main)
        #expect(fromExisting.state.branch == "existing")
        let fromRef = try await svc.create(name: "hotfix", from: "main", in: main)
        #expect(fromRef.created)
    }

    @Test func createSeedsSourcePackagesFromMain() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        try project.write("cached", to: ".xcdev/SourcePackages/checkouts/Yams/marker")
        let svc = service(project)
        let main = try await svc.open(from: project.root)
        let (state, _) = try await svc.create(name: "feat", in: main)
        let seeded = state.path + "/.xcdev/SourcePackages/checkouts/Yams/marker"
        #expect(try String(contentsOfFile: seeded, encoding: .utf8) == "cached")
    }

    @Test func createRejectsBadNames() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let main = try await service(project).open(from: project.root)
        for bad in ["main", "a/b", "-x", "has space", "", "x.lock", "a..b"] {
            let error = await #expect(throws: XcdError.self) { try await service(project).create(name: bad, in: main) }
            #expect(error?.code == .usage, "name \(bad)")
        }
    }

    @Test func failedGitAddRollsBackRegistry() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let svc = service(project)
        let main = try await svc.open(from: project.root)
        let error = await #expect(throws: XcdError.self) { try await svc.create(name: "feat", from: "no-such-ref", in: main) }
        #expect(error?.code == .subprocessFailed)
        #expect(try svc.list(projectRoot: project.root).map(\.name) == ["main"])
    }

    @Test func openByWorktreeName() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let svc = service(project)
        let main = try await svc.open(from: project.root)
        let (feat, _) = try await svc.create(name: "feat", in: main)
        #expect(try await svc.open(from: project.root, worktreeName: "feat").state.id == feat.id)
        #expect(try await svc.open(from: feat.path, worktreeName: "main").state.id == main.state.id)
        let error = await #expect(throws: XcdError.self) { try await svc.open(from: project.root, worktreeName: "nope") }
        #expect(error?.code == .worktreeNotFound)
    }

    @Test func createNeverRemovesPreexistingWorktree() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let target = project.base + "/Sample App.worktrees/foo"
        try TempProject.git(["worktree", "add", "-b", "foo", target], in: project.root)
        try "keep".write(toFile: target + "/marker.txt", atomically: true, encoding: .utf8)
        let svc = service(project)
        let main = try await svc.open(from: project.root)
        let error = await #expect(throws: XcdError.self) { try await svc.create(name: "foo", in: main) }
        #expect(error?.code == .subprocessFailed)
        #expect(FileManager.default.fileExists(atPath: target + "/marker.txt"))
        #expect(try svc.list(projectRoot: project.root).map(\.name) == ["main"])
    }

    @Test func failedCreateLeavesNoDirectoryOrBranch() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let svc = service(project)
        let main = try await svc.open(from: project.root)
        _ = await #expect(throws: XcdError.self) { try await svc.create(name: "feat", from: "no-such-ref", in: main) }
        #expect(!FileManager.default.fileExists(atPath: project.base + "/Sample App.worktrees/feat"))
        let branch = try await SystemProcessRunner().run(.git(["rev-parse", "--verify", "--quiet", "refs/heads/feat"], in: project.root))
        #expect(!branch.succeeded)
    }

    @Test func concurrentCreateOfSameNameIsSafe() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let svc = service(project)
        let main = try await svc.open(from: project.root)
        let results = try await withThrowingTaskGroup(of: (id: String, created: Bool).self) { group in
            for _ in 0..<2 {
                group.addTask {
                    let r = try await svc.create(name: "feat", in: main)
                    return (r.state.id, r.created)
                }
            }
            var all: [(id: String, created: Bool)] = []
            for try await r in group { all.append(r) }
            return all
        }
        #expect(results.count == 2)
        #expect(Set(results.map(\.id)).count == 1)
        #expect(results.filter(\.created).count == 1)
    }

    @Test func listDetailsShowsBranchDevicesAndBootState() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        let svc = service(project)
        var main = try await svc.open(from: project.root)
        _ = try await svc.create(name: "feat", in: main)
        let (doomed, _) = try await svc.create(name: "doomed", in: main)
        let phone = try #require(sims.devices.first)
        try await SimctlClient(runner: fake, developerDir: nil).boot(udid: phone.udid)
        main.state.devices = [
            "watch": ProvisionedDevice(udid: "GONE", deviceType: "W", deviceTypeIdentifier: "w", runtime: "watchOS", runtimeIdentifier: "r"),
            "iphone": ProvisionedDevice(udid: phone.udid, deviceType: "P", deviceTypeIdentifier: "p", runtime: "iOS", runtimeIdentifier: "r"),
        ]
        try WorktreeStateStore.save(main.state, main.paths)
        try FileManager.default.removeItem(atPath: doomed.path)

        let items = try await svc.listDetails(projectRoot: project.root)
        #expect(items.map(\.name) == ["doomed", "feat", "main"])
        #expect(items[0].status == .missing && items[0].branch == nil && items[0].devices.isEmpty)
        #expect(items[1].status == .ready && items[1].branch == "feat" && items[1].devices.isEmpty)
        #expect(items[2].branch == "main")
        #expect(items[2].devices.map(\.name) == ["iphone", "watch"])
        #expect(items[2].devices.map(\.state) == ["Booted", "gone"])
        #expect(fake.commandLines.filter { $0.hasPrefix("xcrun simctl list") }.count == 1)
        #expect(WorktreeListReport(worktrees: items, includeProject: false).text.hasSuffix(
            "main  ready  branch=main  devices=iphone:Booted,watch:gone  \(project.root)"))
    }

    @Test func listDetailsSurvivesSimctlFailure() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        fake.stub(["xcrun", "simctl", "list"], exitCode: 1, stderr: "CoreSimulator is sad")
        let svc = service(project)
        var main = try await svc.open(from: project.root)
        main.state.devices = ["iphone": ProvisionedDevice(udid: "U", deviceType: "P", deviceTypeIdentifier: "p",
                                                          runtime: "iOS", runtimeIdentifier: "r")]
        try WorktreeStateStore.save(main.state, main.paths)
        let items = try await svc.listDetails(projectRoot: project.root)
        #expect(items.map(\.devices) == [[WorktreeListItem.Device(name: "iphone", udid: "U", state: "unknown")]])
    }

    @Test func listDetailsSkipsSimctlWithoutDevices() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let svc = service(project)
        _ = try await svc.open(from: project.root)
        #expect(try await svc.listDetails(projectRoot: project.root).map(\.name) == ["main"])
        #expect(!fake.commandLines.contains { $0.hasPrefix("xcrun simctl") })      // only `du` ran
    }

    @Test func openByNameOfDeletedWorktreeExplains() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let svc = service(project)
        let main = try await svc.open(from: project.root)
        let (feat, _) = try await svc.create(name: "feat", in: main)
        try FileManager.default.removeItem(atPath: feat.path)
        let error = await #expect(throws: XcdError.self) { try await svc.open(from: project.root, worktreeName: "feat") }
        #expect(error?.code == .worktreeNotFound)
        #expect(error?.message == "worktree 'feat' was deleted outside xcd")
        #expect(error?.next == "run `xcd wt remove feat` to clean it up")
    }

    @Test func corruptRegistryExplainsRecovery() throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let paths = GlobalPaths(base: project.home)
        try FileManager.default.createDirectory(atPath: (paths.registryFile as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try "{nope".write(toFile: paths.registryFile, atomically: true, encoding: .utf8)
        let error = #expect(throws: XcdError.self) { try Registry(paths: paths).entries() }
        #expect(error?.next == "move \(Shell.quote(paths.registryFile)) aside; xcd re-registers worktrees as they are opened")
    }

    @Test func gitWorktreeAddGetsLongTimeout() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let recorder = RecordingRunner()
        let svc = WorktreeService(runner: recorder, globalPaths: GlobalPaths(base: project.home))
        let main = try await svc.open(from: project.root)
        _ = try await svc.create(name: "feat", in: main)
        let add = try #require(recorder.calls.first { $0.arguments.contains("add") && $0.arguments.contains("worktree") })
        #expect(add.timeout == .seconds(600))
        #expect(recorder.calls.filter { $0 != add }.allSatisfy { $0.timeout != .seconds(600) })
    }

    @Test func createFromRefRejectedWhenBranchExists() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        try TempProject.git(["branch", "existing"], in: project.root)
        let svc = service(project)
        let main = try await svc.open(from: project.root)
        let error = await #expect(throws: XcdError.self) { try await svc.create(name: "existing", from: "main", in: main) }
        #expect(error?.code == .usage)
        #expect(try svc.list(projectRoot: project.root).map(\.name) == ["main"])
    }
}

/// Runs everything for real and records each invocation.
private final class RecordingRunner: ProcessRunning {
    private let recorded = Mutex<[Invocation]>([])
    var calls: [Invocation] { recorded.withLock { $0 } }

    func run(_ invocation: Invocation) async throws -> ProcessOutput {
        recorded.withLock { $0.append(invocation) }
        return try await SystemProcessRunner().run(invocation)
    }
}
