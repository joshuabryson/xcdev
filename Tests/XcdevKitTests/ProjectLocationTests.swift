import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Answers every git command as a git that found no repository and stopped at a mount point, with `stderr`.
struct MountPointGit: ProcessRunning {
    let stderr: String

    func run(_ invocation: Invocation) async throws -> ProcessOutput {
        ProcessOutput(exitCode: 128, stderr: stderr)
    }
}

/// Finding the project from a directory, when git cannot. Real git.
@Suite struct ProjectLocationTests {
    let locator = WorktreeLocator(runner: SystemProcessRunner())

    /// `path` with its links resolved, as git writes paths: `/private/var/…` where Foundation says `/var/…`.
    static func spelledByGit(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func failure(from directory: String) async -> XcdError? {
        await #expect(throws: XcdError.self) { _ = try await locator.locate(from: directory) }
    }

    /// Every command starts here, so one git call answers both: the checkout's top folder, and the repository's shared
    /// folder, whose parent is the main checkout.
    @Test func oneGitCallFindsTheCheckoutAndTheMainCheckout() async throws {
        let project = try TempProject.make(config: "version: 1\nproject: App.xcodeproj\n")
        defer { project.remove() }
        let worktree = project.base + "/login"
        try project.git("worktree", "add", "-q", "-b", "login", worktree)
        let runner = RecordingRunner()
        let location = try await WorktreeLocator(runner: runner).locate(from: worktree)
        #expect(location == ProjectLocation(projectRoot: project.root, worktreeRoot: Paths.canonical(worktree)))
        #expect(runner.calls.count == 1, "\(runner.calls.map(\.commandLine))")
    }

    @Test func aFolderWithNoGitAboveItIsNotInAProject() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-plain-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir + "/deeper", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let error = await failure(from: dir + "/deeper")
        #expect(error?.code == .notInProject && error?.message == "\(dir)/deeper is not inside a git repository")
        #expect(error?.next == "cd into a project that has a .xcdev.yml (or run `git init`, then `xcd init`)")
    }

    /// git says "(or any parent up to mount point …)" where the search stops at a filesystem boundary, as under `/dev`.
    @Test func aFolderOnAnotherVolumeWithNoGitAboveItIsNotInAProject() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-mount-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stderr = "fatal: not a git repository (or any parent up to mount point /)\n"
            + "Stopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n"
        let error = await #expect(throws: XcdError.self) {
            _ = try await WorktreeLocator(runner: MountPointGit(stderr: stderr)).locate(from: dir)
        }
        #expect(error?.code == .notInProject && error?.message == "\(dir) is not inside a git repository")
    }

    /// git says "not a git repository" for a repository whose HEAD is damaged too, where `git init` is the wrong advice.
    @Test func aRepositoryWithADamagedHeadIsGitFailed() async throws {
        let project = try TempProject.make(config: "version: 1\nproject: App.xcodeproj\n")
        defer { project.remove() }
        try "garbage\n".write(toFile: project.root + "/.git/HEAD", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: project.root + "/Sources", withIntermediateDirectories: true)
        let error = await failure(from: project.root + "/Sources")
        #expect(error?.code == .gitFailed)
        #expect(error?.message == "git failed: not a git repository (or any of the parent directories): .git")
        #expect(error?.next == "fix what git says above, then run the command again")
    }

    /// git names no place it looked (Apple's git says `not a git repository: (null)`); the checkout's `.git` file
    /// names where its repository was.
    @Test func aWorktreeWhoseMainCheckoutWasMovedSaysToAskWhereItIs() async throws {
        let project = try TempProject.make(config: "version: 1\nproject: App.xcodeproj\n")
        defer { project.remove() }
        let worktree = project.base + "/login"
        try project.git("worktree", "add", "-q", "-b", "login", worktree)
        let gitdir = Self.spelledByGit(project.root) + "/.git/worktrees/login"
        try FileManager.default.moveItem(atPath: project.root, toPath: project.base + "/Moved App")
        let error = await failure(from: worktree)
        #expect(error?.code == .gitFailed)
        #expect(error?.message == "this checkout is a git worktree, and its repository is no longer at \(gitdir)")
        #expect(error?.next == "ask the user where the main checkout is now; `git worktree repair` run there reconnects this checkout. "
                    + "If it was deleted, this checkout cannot be repaired")
        #expect(error?.details.contains { $0.hasPrefix("fatal: not a git repository") } == true)
    }

    @Test func aRepositoryAnotherUserOwnsIsGitFailed() async throws {
        let project = try TempProject.make(config: "version: 1\nproject: App.xcodeproj\n")
        defer { project.remove() }
        let error = await #expect(throws: XcdError.self) { _ = try await WorktreeLocator(runner: OwnedByAnotherUser()).locate(from: project.root) }
        #expect(error?.code == .gitFailed && error?.message == "git refuses this repository because another user owns it")
    }

    /// The lock of the branch `wt create` makes is held: git's advice to delete it could break another agent's work.
    @Test func aHeldLockFileStopsWorktreeCreateAndSaysToWait() async throws {
        let project = try TempProject.make(config: "version: 1\nproject: App.xcodeproj\n")
        defer { project.remove() }
        let svc = WorktreeService(runner: SystemProcessRunner(), globalPaths: GlobalPaths(base: project.home))
        let main = try await svc.open(from: project.root)
        let lock = project.root + "/.git/refs/heads/login.lock"
        try "".write(toFile: lock, atomically: true, encoding: .utf8)
        let error = await #expect(throws: XcdError.self) { _ = try await svc.createRecordingBase(name: "login", in: main) }
        #expect(error?.code == .gitFailed)
        #expect(error?.next == "another git command is using this repository, maybe another agent's: wait a moment and run the command again; "
                    + "ask the user before deleting \(Self.spelledByGit(lock))")
        #expect(FileManager.default.fileExists(atPath: lock))
    }
}
