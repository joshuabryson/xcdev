import Foundation
import Synchronization
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The first xcd command in a checkout xcd did not make.
@Suite struct FirstUseTests {
    func service(_ project: TempProject) -> WorktreeService {
        WorktreeService(runner: RoutingRunner(fake: FakeProcessRunner()), globalPaths: GlobalPaths(base: project.home))
    }

    /// A worktree made with plain git at `<base>/<relative>`, on a new branch.
    func plainWorktree(_ project: TempProject, at relative: String) throws -> String {
        let path = project.base + "/" + relative
        try TempProject.git(["worktree", "add", "-q", "-b", relative.replacingOccurrences(of: "/", with: "-"), path], in: project.root)
        return Paths.canonical(path)
    }

    @Test func twoFoldersOfTheSameNameGetTwoNamesAndTwoEntries() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        let svc = service(project)
        let first = try await svc.open(from: try plainWorktree(project, at: "codex/a1b2/pkg"))
        let second = try await svc.open(from: try plainWorktree(project, at: "codex/c3d4/pkg"))
        #expect(first.state.name == "pkg" && second.state.name == "c3d4-pkg")
        #expect(try svc.list(projectRoot: project.root).map(\.name) == ["c3d4-pkg", "pkg"])
        #expect(try await svc.open(from: first.state.path).state.name == "pkg")         // kept on later commands
    }

    @Test func aFolderCalledMainIsNamedWithItsParent() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        let ctx = try await service(project).open(from: try plainWorktree(project, at: "wt/main"))
        #expect(ctx.state.name == "wt-main")
    }

    @Test func aGoneCheckoutsEntryStillHoldsItsName() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        let svc = service(project)
        let gone = try plainWorktree(project, at: "one/pkg")
        _ = try await svc.open(from: gone)
        try TempProject.git(["worktree", "remove", "--force", gone], in: project.root)
        let ctx = try await svc.open(from: try plainWorktree(project, at: "two/pkg"))
        #expect(ctx.state.name == "two-pkg")
        #expect(try svc.list(projectRoot: project.root).map(\.name) == ["pkg", "two-pkg"])
    }

    @Test func aCheckoutWhoseStateWasDeletedKeepsItsEntrysName() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        let svc = service(project)
        _ = try await svc.open(from: try plainWorktree(project, at: "a/pkg"))
        let path = try plainWorktree(project, at: "b/pkg")
        #expect(try await svc.open(from: path).state.name == "b-pkg")
        try FileManager.default.removeItem(atPath: path + "/.xcdev")
        #expect(try await svc.open(from: path).state.name == "b-pkg")
        #expect(try svc.list(projectRoot: project.root).map(\.name) == ["b-pkg", "pkg"])
    }

    /// `operation`'s result, or nil when it has not finished within `seconds`. It is then left running: a lock it waits
    /// on would never let it finish, and a time limit cannot stop a thread blocked in `flock`.
    static func finished<T: Sendable>(within seconds: Int, _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
        let outcome = Mutex<Result<T, any Error>?>(nil)
        Task {
            do {
                let value = try await operation()
                outcome.withLock { $0 = .success(value) }
            } catch {
                outcome.withLock { $0 = .failure(error) }
            }
        }
        for _ in 0..<(seconds * 10) {
            if let result = outcome.withLock({ $0 }) { return try result.get() }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// `wt create` holds the project's lock when it meets its own worktree with no state; setting it up again must not
    /// wait on that lock.
    @Test func createSetsUpItsOwnWorktreeWhoseStateWasDeleted() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        let svc = service(project)
        let main = try await svc.open(from: project.root)
        let first = try await svc.create(name: "feat", in: main)
        try FileManager.default.removeItem(atPath: first.state.path + "/.xcdev")
        let again = try #require(try await Self.finished(within: 20) { try await svc.create(name: "feat", in: main) },
                                 "wt create waited on the project's lock, which it holds")
        #expect(!again.created && again.state.name == "feat" && again.state.path == first.state.path)
    }

    @Test func twoFirstCommandsAtOnceInOneCheckoutMakeOneState() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        let svc = service(project)
        let path = try plainWorktree(project, at: "wt/feature")
        async let one = svc.open(from: path)
        async let two = svc.open(from: path)
        let (first, second) = try await (one, two)
        #expect(first.state.id == second.state.id)
        #expect(try svc.list(projectRoot: project.root).map(\.name) == ["feature"])
    }

    @Test func aWorktreeGetsTheMainCheckoutsPackagesAndTheMainCheckoutGetsNone() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        try project.write("pin\n", to: ".xcdev/SourcePackages/workspace-state.json")
        let svc = service(project)
        let ctx = try await svc.open(from: try plainWorktree(project, at: "wt/feature"))
        #expect(try String(contentsOfFile: ctx.paths.sourcePackages + "/workspace-state.json", encoding: .utf8) == "pin\n")
        // Only the state is deleted, so the packages are still there: they are not copied over again.
        try FileManager.default.removeItem(atPath: WorktreePaths(root: ctx.location.worktreeRoot).stateFile)
        _ = try await svc.open(from: ctx.location.worktreeRoot)
        #expect(!FileManager.default.fileExists(atPath: ctx.paths.sourcePackages + "/SourcePackages"))
        #expect(try String(contentsOfFile: ctx.paths.sourcePackages + "/workspace-state.json", encoding: .utf8) == "pin\n")
        #expect(try await svc.open(from: project.root).state.name == "main")
    }

    /// The copy is a speed-up: when `cp` fails, the first command still succeeds, with no packages and a note.
    @Test func aPackageCopyThatFailsLeavesNothingAndSaysSo() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        let locked = project.root + "/.xcdev/SourcePackages/checkouts/locked"
        try project.write("x\n", to: ".xcdev/SourcePackages/checkouts/locked/file")
        // Registered before the change, so the folder is readable again however the test ends.
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
        let svc = service(project)
        let ctx = try await svc.open(from: try plainWorktree(project, at: "wt/feature"))
        #expect(!FileManager.default.fileExists(atPath: ctx.paths.sourcePackages))
        #expect(try WorktreeStateStore.load(ctx.paths) != nil)
        #expect(svc.notes.all == [FirstUseSetup.packagesNotCopied])
    }

    /// A worktree with a leftover `SourcePackages.partial` (and `own` files already in its `SourcePackages`), opened.
    func openWithLeftover(_ project: TempProject, own: Bool) async throws -> String {
        try project.write("pin\n", to: ".xcdev/SourcePackages/workspace-state.json")
        let path = try plainWorktree(project, at: "codex/a1b2/pkg")
        if own { try project.write("theirs\n", to: ".xcdev/SourcePackages/theirs.json", in: path) }
        try project.write("half\n", to: ".xcdev/SourcePackages.partial/half.json", in: path)
        _ = try await service(project).open(from: path)
        #expect(!FileManager.default.fileExists(atPath: path + "/.xcdev/SourcePackages.partial"))
        return path + "/.xcdev/SourcePackages/"
    }

    @Test func aLeftoverPartialCopyBesideExistingPackagesIsRemovedAndThePackagesAreKept() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        let packages = try await openWithLeftover(project, own: true)
        #expect(FileManager.default.fileExists(atPath: packages + "theirs.json"))
    }

    /// A copy Ctrl-C cut short leaves `SourcePackages.partial`, which the next first use removes before copying again.
    @Test func aLeftoverPartialCopyIsRemovedAndThePackagesAreCopied() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        let packages = try await openWithLeftover(project, own: false)
        #expect(FileManager.default.fileExists(atPath: packages + "workspace-state.json"))
        #expect(!FileManager.default.fileExists(atPath: packages + "half.json"))
    }
}
