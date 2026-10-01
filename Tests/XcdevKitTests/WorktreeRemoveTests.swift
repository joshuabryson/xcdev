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
}
