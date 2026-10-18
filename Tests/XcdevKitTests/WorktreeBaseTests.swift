import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// What `xcd worktree create` records as the ref a worktree's work is measured against.
@Suite struct WorktreeBaseTests {
    static let config = "version: 1\nproject: App.xcodeproj\n"

    let fake = FakeProcessRunner()

    func service(_ project: TempProject) -> WorktreeService {
        WorktreeService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home))
    }

    /// A project whose main checkout is on `main` with two commits, a branch `develop`, and a tag `v1`.
    func project() throws -> TempProject {
        let project = try TempProject.make(config: Self.config)
        try project.write("more\n", to: "README.md")
        try TempProject.git(["-c", "user.name=xcd", "-c", "user.email=xcd@example.com", "commit", "-q", "-am", "Second"], in: project.root)
        try TempProject.git(["branch", "develop"], in: project.root)
        try TempProject.git(["tag", "v1"], in: project.root)
        return project
    }

    func commit(_ ref: String, in project: TempProject) async throws -> String {
        let out = try await SystemProcessRunner().runChecked(.git(["rev-parse", ref], in: project.root))
        return out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func aNewWorktreeRecordsTheBranchTheMainCheckoutIsOn() async throws {
        let project = try project()
        defer { project.remove() }
        let svc = service(project)
        let made = try await svc.createRecordingBase(name: "login", in: try await svc.open(from: project.root))
        #expect(made.state.base == "main" && made.branchCreated)
        #expect(try await svc.open(from: made.state.path).state.base == "main")      // it is in worktree.json
    }

    @Test func aRefThatNamesABranchOrATagIsRecordedByThatName() async throws {
        let project = try project()
        defer { project.remove() }
        let svc = service(project)
        let main = try await svc.open(from: project.root)
        #expect(try await svc.createRecordingBase(name: "a", from: "develop", in: main).state.base == "develop")
        #expect(try await svc.createRecordingBase(name: "b", from: "refs/heads/develop", in: main).state.base == "develop")
        #expect(try await svc.createRecordingBase(name: "c", from: "v1", in: main).state.base == "v1")
        #expect(try await svc.createRecordingBase(name: "d", from: "HEAD", in: main).state.base == "main")
    }

    @Test func aRefThatNamesNoBranchIsRecordedAsItsCommit() async throws {
        let project = try project()
        defer { project.remove() }
        let svc = service(project)
        let main = try await svc.open(from: project.root)
        let first = try await commit("HEAD~1", in: project)
        #expect(try await svc.createRecordingBase(name: "a", from: "HEAD~1", in: main).state.base == first)
        #expect(try await svc.createRecordingBase(name: "b", from: String(first.prefix(9)), in: main).state.base == first)
    }

    @Test func aMainCheckoutOnNoBranchRecordsItsCommit() async throws {
        let project = try project()
        defer { project.remove() }
        try TempProject.git(["checkout", "-q", "--detach"], in: project.root)
        let svc = service(project)
        let state = try await svc.createRecordingBase(name: "login", in: try await svc.open(from: project.root)).state
        #expect(state.base == (try await commit("HEAD", in: project)))
    }

    @Test func aRemoteBranchIsRecordedWithItsRemote() async throws {
        let project = try project()
        defer { project.remove() }
        try TempProject.git(["update-ref", "refs/remotes/origin/main", "HEAD~1"], in: project.root)
        let svc = service(project)
        let state = try await svc.createRecordingBase(name: "login", from: "origin/main", in: try await svc.open(from: project.root)).state
        #expect(state.base == "origin/main")
    }

    @Test func aReusedBranchRecordsNothing() async throws {
        let project = try project()
        defer { project.remove() }
        let svc = service(project)
        let made = try await svc.createRecordingBase(name: "develop", in: try await svc.open(from: project.root))
        #expect(made.state.branch == "develop" && made.state.base == nil && !made.branchCreated)
    }

    /// A worktree.json written before the entry existed has no `base` key.
    @Test func aStateFileFromBeforeTheEntryStillLoads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-base-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = WorktreePaths(root: root)
        var state = WorktreeState(id: "id", name: "feat", project: "App", projectRoot: "/p", path: root, branch: "feat",
                                  xcode: nil, devices: [:], status: .ready, createdAt: Date(timeIntervalSince1970: 1_790_040_000))
        try WorktreeStateStore.save(state, paths)
        let written = try String(contentsOfFile: paths.stateFile, encoding: .utf8)
        #expect(!written.contains("\"base\""))
        #expect(try WorktreeStateStore.load(paths) == state)

        state.base = "main"
        try WorktreeStateStore.save(state, paths)
        #expect(try WorktreeStateStore.load(paths)?.base == "main")
    }
}
