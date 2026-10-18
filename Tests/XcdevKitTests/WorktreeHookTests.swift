import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct WorktreeHookTests {
    let fake = FakeProcessRunner()

    /// A project whose committed .xcdev.yml has `hooks`, with git, cp, and sh run for real.
    func setup(hooks: String) async throws -> (TempProject, WorktreeService, WorktreeContext) {
        let project = try TempProject.make(config: WorktreeServiceTests.config + "\nhooks:\n" + hooks)
        let runner = RoutingRunner(fake: fake, realExecutables: ["git", "cp", "mv", "sh"])
        let svc = WorktreeService(runner: runner, globalPaths: GlobalPaths(base: project.home),
                                  hooks: HookRunner(runner: runner))
        return (project, svc, try await svc.open(from: project.root))
    }

    /// Commits branch `name` in the main checkout with its .xcdev.yml replaced by `config` (deleted when nil).
    func makeBranch(_ name: String, config: String?, in project: TempProject) throws {
        let git = { (args: [String]) in try TempProject.git(args, in: project.root) }
        try git(["checkout", "-q", "-b", name])
        if let config {
            try project.write(config, to: ".xcdev.yml")
            try git(["add", ".xcdev.yml"])
        } else {
            try git(["rm", "-q", ".xcdev.yml"])
        }
        try git(["-c", "user.name=xcd", "-c", "user.email=xcd@example.com", "commit", "-q", "-m", "Config"])
        try git(["checkout", "-q", "main"])
    }

    @Test func postWorktreeCreateRunsInTheNewWorktree() async throws {
        let (project, svc, main) = try await setup(hooks: #"  post-worktree-create: 'echo "$XCD_WORKTREE_NAME $(basename "$PWD")" > "$XCD_PROJECT_ROOT/../created.txt"'"#)
        defer { project.remove() }
        let made = try await svc.createRecordingBase(name: "feat", in: main)
        #expect(made.created && made.hookRan && made.branchCreated && made.state.status == .ready)
        #expect(try String(contentsOfFile: project.base + "/created.txt", encoding: .utf8) == "feat feat\n")
        let logs = try FileManager.default.contentsOfDirectory(atPath: main.paths.logs)
        #expect(logs.contains { $0.hasSuffix("-hook-post-worktree-create.log") })
        #expect(try svc.list(projectRoot: project.root).first { $0.name == "feat" }?.status == .ready)
    }

    @Test func aFailedCreateHookRollsTheWorktreeBack() async throws {
        let (project, svc, main) = try await setup(hooks: "  post-worktree-create: 'echo bootstrap failed >&2; exit 5'")
        defer { project.remove() }
        let error = await #expect(throws: XcdError.self) { try await svc.create(name: "feat", in: main) }
        #expect(error?.code == .hookFailed)
        #expect(error?.next == "fix hooks.post-worktree-create (its output is in the log), then re-run `xcd wt create feat`")
        #expect(error?.details.contains("bootstrap failed") == true)
        #expect(error?.details.last == "the worktree was not created: its checkout and branch were rolled back")
        #expect(!FileManager.default.fileExists(atPath: project.base + "/Sample App.worktrees/feat"))
        #expect(try svc.list(projectRoot: project.root).map(\.name) == ["main"])
        #expect(throws: XcdError.self) { try TempProject.git(["rev-parse", "--verify", "refs/heads/feat"], in: project.root) }
    }

    @Test func theCreateHookComesFromTheNewCheckoutAndIsSkippedWhenItHasNoConfig() async throws {
        let (project, svc, main) = try await setup(hooks: #"  post-worktree-create: 'echo ran > "$XCD_PROJECT_ROOT/../created.txt"'"#)
        defer { project.remove() }
        try makeBranch("bare", config: nil, in: project)
        let made = try await svc.createRecordingBase(name: "bare", in: main)
        #expect(made.created && !made.hookRan && !made.branchCreated && made.state.status == .ready)
        #expect(!FileManager.default.fileExists(atPath: project.base + "/created.txt"))   // the caller's hook never runs
    }

    @Test func anInvalidConfigInTheNewCheckoutIsConfigInvalidAndRollsBack() async throws {
        let (project, svc, main) = try await setup(hooks: #"  post-worktree-create: 'echo ran > "$XCD_PROJECT_ROOT/../created.txt"'"#)
        defer { project.remove() }
        try makeBranch("broken", config: WorktreeServiceTests.config + "\nbogus: 1\n", in: project)
        let error = await #expect(throws: XcdError.self) { try await svc.create(name: "broken", in: main) }
        #expect(error?.code == .configInvalid)
        #expect(error?.next == "fix .xcdev.yml on branch 'broken', then re-run `xcd wt create broken`")
        #expect(error?.details.last == "the worktree was not created: its checkout was rolled back, and branch 'broken', which already existed, was kept")
        #expect(!FileManager.default.fileExists(atPath: project.base + "/Sample App.worktrees/broken"))
        #expect(!FileManager.default.fileExists(atPath: project.base + "/created.txt"))
        #expect(try svc.list(projectRoot: project.root).map(\.name) == ["main"])
        try TempProject.git(["rev-parse", "--verify", "refs/heads/broken"], in: project.root)   // existing branch kept
    }

    @Test func preWorktreeRemoveRunsFirstAndAFailureKeepsTheWorktree() async throws {
        let (project, svc, main) = try await setup(hooks: #"  pre-worktree-remove: 'echo "$XCD_WORKTREE_NAME" >> "$XCD_PROJECT_ROOT/../removed.txt"; test ! -f "$XCD_PROJECT_ROOT/../block"'"#)
        defer { project.remove() }
        let (state, _) = try await svc.create(name: "feat", in: main)
        try "".write(toFile: project.base + "/block", atomically: true, encoding: .utf8)
        let error = await #expect(throws: XcdError.self) { try await svc.remove(name: "feat", in: main) }
        #expect(error?.code == .hookFailed)
        #expect(error?.details.last == "the worktree was kept")
        #expect(FileManager.default.fileExists(atPath: state.path))

        try FileManager.default.removeItem(atPath: project.base + "/block")
        let removal = try await svc.remove(name: "feat", in: main)
        #expect(removal.warnings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: state.path))
        #expect(try String(contentsOfFile: project.base + "/removed.txt", encoding: .utf8) == "feat\nfeat\n")
    }

    @Test func aDirtyWorktreeIsRefusedBeforeTheRemoveHookRuns() async throws {
        let (project, svc, main) = try await setup(hooks: #"  pre-worktree-remove: 'echo ran >> "$XCD_PROJECT_ROOT/../removed.txt"'"#)
        defer { project.remove() }
        let (state, _) = try await svc.create(name: "feat", in: main)
        try project.write("change", to: "README.md", in: state.path)
        let error = await #expect(throws: XcdError.self) { try await svc.remove(name: "feat", in: main) }
        #expect(error?.code == .worktreeDirty)
        #expect(!FileManager.default.fileExists(atPath: project.base + "/removed.txt"))
        #expect(FileManager.default.fileExists(atPath: state.path))
    }

    /// `git worktree remove --force` would discard tracked edits made while the hook ran; its own untracked files are fine.
    @Test func trackedChangesMadeDuringTheRemoveHookKeepTheWorktree() async throws {
        let (project, svc, main) = try await setup(hooks: #"  pre-worktree-remove: 'echo teardown > teardown.log; test ! -f "$XCD_PROJECT_ROOT/../edit" || echo edited >> README.md'"#)
        defer { project.remove() }
        let (state, _) = try await svc.create(name: "feat", in: main)
        try "".write(toFile: project.base + "/edit", atomically: true, encoding: .utf8)
        let error = await #expect(throws: XcdError.self) { try await svc.remove(name: "feat", in: main) }
        #expect(error?.code == .worktreeDirty)
        #expect(error?.message == "worktree 'feat' has uncommitted changes")
        #expect(error?.details == [" M README.md"])
        #expect(FileManager.default.fileExists(atPath: state.path))
        #expect(try svc.list(projectRoot: project.root).contains { $0.name == "feat" })

        try TempProject.git(["checkout", "--", "README.md"], in: state.path)
        try FileManager.default.removeItem(atPath: project.base + "/edit")
        try FileManager.default.removeItem(atPath: state.path + "/teardown.log")
        let removal = try await svc.remove(name: "feat", in: main)          // the hook's untracked log doesn't block
        #expect(removal.warnings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: state.path))
    }

    @Test func forceRemovesDespiteAFailingRemoveHookAndWarns() async throws {
        let (project, svc, main) = try await setup(hooks: "  pre-worktree-remove: 'echo teardown failed >&2; exit 3'")
        defer { project.remove() }
        let (state, _) = try await svc.create(name: "feat", in: main)
        let removal = try await svc.remove(name: "feat", force: true, in: main)
        #expect(!FileManager.default.fileExists(atPath: state.path))
        #expect(removal.warnings.count == 1)
        #expect(removal.warnings.first?.hasPrefix("the pre-worktree-remove hook failed (exit 3); removed anyway because of --force (log: ") == true)
        #expect(removal.text.contains("\nwarning: the pre-worktree-remove hook failed (exit 3)"))
    }

    /// The hooks can take 30 minutes, so they must not hold the per-project lock that other creates and removes wait on.
    @Test func worktreeHooksRunOutsideTheProjectLock() async throws {
        let check = #"sh "$XCD_PROJECT_ROOT/../check-lock.sh""#
        let (project, svc, main) = try await setup(hooks: "  post-worktree-create: '\(check)'\n  pre-worktree-remove: '\(check)'")
        defer { project.remove() }
        // lockf exits 75 at once if anyone holds the lock (-t 0), and keeps the file (-k).
        try "lockf -k -t 0 \(Shell.quote(svc.lockPath(projectRoot: project.root))) true\n"
            .write(toFile: project.base + "/check-lock.sh", atomically: true, encoding: .utf8)
        let (state, created) = try await svc.create(name: "feat", in: main)
        #expect(created && state.status == .ready)
        _ = try await svc.remove(name: "feat", in: main)
        #expect(!FileManager.default.fileExists(atPath: state.path))
    }

    /// A project with both worktree hooks configured, whose `sh` runs on the fake instead, so a test can stand in
    /// for what the hook does (here: what `xcd build` would record in the new worktree's worktree.json).
    func setupWithFakeHooks() async throws -> (TempProject, WorktreeService, WorktreeContext, FakeSimulators) {
        let project = try TempProject.make(config: WorktreeServiceTests.config
            + "\nhooks:\n  post-worktree-create: ./bootstrap.sh\n  pre-worktree-remove: ./teardown.sh\n")
        let runner = RoutingRunner(fake: fake, realExecutables: ["git", "cp", "mv"])
        let svc = WorktreeService(runner: runner, globalPaths: GlobalPaths(base: project.home),
                                  hooks: HookRunner(runner: runner))
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        return (project, svc, try await svc.open(from: project.root), sims)
    }

    static let xcode = XcodeInstall(path: "/Applications/Xcode.app", version: "27.0", build: "27A266a")
    static let clone = ProvisionedDevice(udid: "4CEABB59-81A5-4060-9573-99D2BA1BA97B", deviceType: "iPhone 18 Pro",
                                         deviceTypeIdentifier: "t", runtime: "iOS 27.0", runtimeIdentifier: "r")

    /// Stubs the post-create hook to pin an Xcode and record a clone in the worktree it runs in, then exit `exitCode`.
    func stubBootstrap(exitCode: Int32) {
        fake.stub(["sh", "-c", "./bootstrap.sh"]) { invocation in
            let paths = WorktreePaths(root: invocation.workingDirectory!)
            var state = try WorktreeStateStore.load(paths)!
            state.xcode = Self.xcode
            state.devices["iphone"] = Self.clone
            try WorktreeStateStore.save(state, paths)
            return ProcessOutput(exitCode: exitCode, stdout: "", stderr: "")
        }
    }

    @Test func markingReadyKeepsWhatTheCreateHookRecorded() async throws {
        let (project, svc, main, _) = try await setupWithFakeHooks()
        defer { project.remove() }
        stubBootstrap(exitCode: 0)
        let (state, created) = try await svc.create(name: "feat", in: main)
        #expect(created)
        for stored in [state, try WorktreeStateStore.load(WorktreePaths(root: state.path))!] {
            #expect(stored.status == .ready)
            #expect(stored.xcode == Self.xcode)
            #expect(stored.devices["iphone"] == Self.clone)
        }
        #expect(try svc.list(projectRoot: project.root).first { $0.name == "feat" }?.status == .ready)
    }

    @Test func aFailedCreateHookDeletesTheClonesItMade() async throws {
        let (project, svc, main, sims) = try await setupWithFakeHooks()
        defer { project.remove() }
        stubBootstrap(exitCode: 5)
        let error = await #expect(throws: XcdError.self) { try await svc.create(name: "feat", in: main) }
        #expect(error?.code == .hookFailed)
        #expect(fake.commandLines.contains { $0.hasSuffix("simctl delete \(Self.clone.udid)") })
        #expect(sims.devices.allSatisfy { $0.udid != Self.clone.udid })
        #expect(!FileManager.default.fileExists(atPath: project.base + "/Sample App.worktrees/feat"))
        #expect(try svc.list(projectRoot: project.root).map(\.name) == ["main"])
    }
}
