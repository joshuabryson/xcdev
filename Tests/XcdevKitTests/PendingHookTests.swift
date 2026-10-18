import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The `post-worktree-create` hook of a worktree xcd did not make.
@Suite struct PendingHookTests {
    /// A hook that writes its name and the worktree's to `<base>/runs.log`, and fails while `<base>/fail` is there.
    static let config = WorktreeServiceTests.config + """

    hooks:
      post-worktree-create: 'test ! -f "$XCD_PROJECT_ROOT/../fail" && echo "$XCD_HOOK $XCD_WORKTREE_NAME" >> "$XCD_PROJECT_ROOT/../runs.log"'
    """
    static let waiting = "post-worktree-create hasn't run in this worktree, because it has uncommitted changes the hook could "
        + "overwrite: ask the user. It runs on the first xcd command at which the worktree has none."

    let fake = FakeProcessRunner()
    var routing: RoutingRunner { RoutingRunner(fake: fake, realExecutables: ["git", "cp", "mv", "sh"]) }

    func service(_ project: TempProject) -> WorktreeService {
        WorktreeService(runner: routing, globalPaths: GlobalPaths(base: project.home), hooks: HookRunner(runner: routing))
    }

    func runs(_ project: TempProject) -> [String] {
        ((try? String(contentsOfFile: project.base + "/runs.log", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func worktree(_ project: TempProject, _ name: String = "feature") throws -> String {
        try FirstUseTests().plainWorktree(project, at: "wt/" + name)
    }

    @Test func theFirstCommandOnACleanWorktreeRunsTheHookOnce() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let svc = service(project)
        let path = try worktree(project)
        #expect(try await svc.open(from: path).state.hookPending == nil)
        _ = try await svc.open(from: path)
        #expect(runs(project) == ["post-worktree-create feature"])
        #expect(try WorktreeStateStore.load(WorktreePaths(root: path))?.hookPending == nil)
    }

    @Test func aWorktreeWithChangesKeepsTheHookWaitingAndSaysWhy() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        try TempProject.git(["config", "status.showUntrackedFiles", "no"], in: project.root)
        let svc = service(project)
        let path = try worktree(project)
        try project.write("draft\n", to: "Notes.md", in: path)
        #expect(try await svc.open(from: path).state.hookPending == true)
        #expect(runs(project).isEmpty && svc.notes.all == [Self.waiting])
        try FileManager.default.removeItem(atPath: path + "/Notes.md")
        #expect(try await service(project).open(from: path).state.hookPending == nil)
        #expect(runs(project) == ["post-worktree-create feature"])
    }

    @Test func aFailingHookFailsTheCommandAndRunsAgainOnTheNext() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let path = try worktree(project)
        try project.write("", to: "fail", in: project.base)
        let error = await #expect(throws: XcdError.self) { try await service(project).open(from: path) }
        #expect(error?.code == .hookFailed)
        #expect(error?.next == FirstUseSetup.failedNext)
        #expect(FirstUseSetup.failedNext.contains("`hooks: { post-worktree-create: \"\" }` in its .xcdev.local.yml, which then replaces the main checkout's .xcdev.local.yml here"))
        #expect(try WorktreeStateStore.load(WorktreePaths(root: path))?.hookPending == true)
        try FileManager.default.removeItem(atPath: project.base + "/fail")
        _ = try await service(project).open(from: path)
        #expect(runs(project) == ["post-worktree-create feature"])
    }

    @Test func commandsThatOnlyLookLeaveItPendingAndStatusShowsIt() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let ctx = try await service(project).open(from: try worktree(project), runsPendingHook: false)
        #expect(runs(project).isEmpty && ctx.state.hookPending == true)
        #expect(WorktreeStatusReport(worktree: ctx.state).text.hasPrefix("worktree feature  branch=wt-feature status=ready hook=pending\n"))
    }

    @Test func aCommandRunInsideAHookNeverRunsAPendingHook() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let path = try worktree(project)
        let services = Services(runner: routing, globalPaths: GlobalPaths(base: project.home), currentDirectory: path,
                                environment: ["XCD_HOOK": "post-worktree-create"])
        #expect(try await services.open(worktree: nil).state.hookPending == true)
        #expect(runs(project).isEmpty)
        _ = try await Services(runner: routing, globalPaths: GlobalPaths(base: project.home), currentDirectory: path,
                               environment: [:]).open(worktree: nil)
        #expect(runs(project) == ["post-worktree-create feature"])
    }

    @Test func aBorrowedConfigKeepsItPendingUntilTheBranchHasItsOwn() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let path = try BorrowedConfigTests.worktreeWithoutConfig(project)
        #expect(try await service(project).open(from: path).state.hookPending == true)
        #expect(runs(project).isEmpty)
        try TempProject.git(["checkout", "main", "--", ".xcdev.yml"], in: path)
        try TempProject.git(["-c", "user.name=xcd", "-c", "user.email=xcd@example.com", "commit", "-q", "-m", "Config"], in: path)
        _ = try await service(project).open(from: path)
        #expect(runs(project) == ["post-worktree-create old"])
    }

    @Test func aConfigWithoutTheHookLeavesNothingPending() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        #expect(try await service(project).open(from: try worktree(project)).state.hookPending == nil)
        #expect(try await service(project).open(from: try worktree(project, "look"), runsPendingHook: false).state.hookPending == nil)
    }

    @Test func aCheckoutWhoseStateWasDeletedDoesNotRunTheHookAgain() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let svc = service(project)
        let path = try worktree(project)
        _ = try await svc.open(from: path)
        try FileManager.default.removeItem(atPath: path + "/.xcdev")
        let again = try await service(project).open(from: path)
        #expect(runs(project) == ["post-worktree-create feature"] && again.state.hookPending == nil)
        let main = try await svc.open(from: project.root, runsPendingHook: false)
        let made = try await svc.create(name: "made", in: main)
        try FileManager.default.removeItem(atPath: made.state.path + "/.xcdev")
        _ = try await service(project).open(from: made.state.path)
        #expect(runs(project) == ["post-worktree-create feature", "post-worktree-create made"])
    }

    @Test func theMainCheckoutAndXcdsOwnWorktreesHaveNoPendingHook() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let svc = service(project)
        let main = try await svc.open(from: project.root, runsPendingHook: false)
        #expect(main.state.hookPending == nil)
        let made = try await svc.create(name: "made", in: main)
        #expect(made.state.hookPending == nil && runs(project) == ["post-worktree-create made"])
    }

    @Test func aBorrowingWorktreeStaysPendingWhateverTheMainConfigHasAndRunsNothing() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        let path = try BorrowedConfigTests.worktreeWithoutConfig(project)
        #expect(try await service(project).open(from: path).state.hookPending == true)
        #expect(try await service(project).open(from: path).state.hookPending == true)
        #expect(runs(project).isEmpty)
    }

    @Test func anOwnHookThatIsBlankIsNoHook() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config + "\nhooks:\n  post-worktree-create: ' '\n")
        defer { project.remove() }
        let state = try await service(project).open(from: try worktree(project), runsPendingHook: false).state
        #expect(state.hookPending == nil)
    }

    @Test func aLocalEmptyOverrideClearsAFailingPendingHookWithoutRunningIt() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let path = try worktree(project)
        try project.write("", to: "fail", in: project.base)
        _ = await #expect(throws: XcdError.self) { try await service(project).open(from: path) }
        try project.write("hooks:\n  post-worktree-create: \"\"\n", to: ".xcdev.local.yml", in: path)
        try FileManager.default.removeItem(atPath: project.base + "/fail")
        #expect(try await service(project).open(from: path).state.hookPending == nil)
        #expect(runs(project).isEmpty)
    }

    @Test func aStateRemovedWhileTheCommandWaitedFailsInsteadOfBeingSavedAgain() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let svc = service(project)
        let path = try worktree(project)
        let ctx = try await svc.open(from: path, runsPendingHook: false)
        #expect(ctx.state.hookPending == true)
        try FileManager.default.removeItem(atPath: path + "/.xcdev/worktree.json")
        let error = await #expect(throws: XcdError.self) { try await FirstUseSetup(service: svc).runPendingHook(ctx) }
        #expect(error?.code == .worktreeNotFound)
        #expect(!FileManager.default.fileExists(atPath: path + "/.xcdev/worktree.json"))
    }
}
