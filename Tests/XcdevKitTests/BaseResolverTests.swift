import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The ref a change is measured against, and where the work left it. Real git, throwaway repos.
@Suite struct BaseResolverTests {
    let resolver = BaseResolver(runner: SystemProcessRunner())

    /// `main` with one commit, then branch `work` checked out with one more.
    func project() throws -> (project: TempProject, first: String) {
        let project = try TempProject.make(config: "version: 1\nproject: App.xcodeproj\n")
        let first = try project.rev("HEAD")
        try project.git("checkout", "-q", "-b", "work")
        try project.write("work\n", to: "work.txt")
        try project.commit("Work")
        return (project, first)
    }

    func usage(_ body: () async throws -> ResolvedBase) async -> XcdError? {
        let error = await #expect(throws: XcdError.self) { _ = try await body() }
        #expect(error?.code == .usage)
        return error
    }

    @Test func theFlagWinsOverTheRecordedRefWhichWinsOverTheDefaultBranch() async throws {
        let (project, first) = try project()
        defer { project.remove() }
        try project.git("branch", "develop", "work")
        try project.git("tag", "v1", "work")
        let workTip = try project.rev("work")

        let flagged = try await resolver.resolve(in: project.root, flag: "v1", recorded: "develop")
        #expect(flagged == ResolvedBase(name: "v1", forkPoint: workTip))
        let recorded = try await resolver.resolve(in: project.root, flag: nil, recorded: "develop")
        #expect(recorded == ResolvedBase(name: "develop", forkPoint: workTip))
        let fallback = try await resolver.resolve(in: project.root, flag: nil, recorded: nil)
        #expect(fallback == ResolvedBase(name: "main", forkPoint: first))
    }

    /// The branch was made from a local `main` that is ahead of `origin/main`: the unpushed commit is not the change.
    @Test func aLocalBranchAheadOfItsOriginCopyGivesTheLocalForkPoint() async throws {
        let (project, first) = try project()
        defer { project.remove() }
        try project.git("update-ref", "refs/remotes/origin/main", first)
        try project.git("checkout", "-q", "main")
        try project.write("unpushed\n", to: "unpushed.txt")
        let unpushed = try project.commit("Unpushed")
        try project.git("checkout", "-q", "-b", "feature")
        try project.write("feature\n", to: "feature.txt")
        try project.commit("Feature")

        #expect(try await resolver.resolve(in: project.root, flag: nil, recorded: "main") == ResolvedBase(name: "main", forkPoint: unpushed))
    }

    /// The branch was made from an `origin/main` that the local `main` has not caught up with.
    @Test func anOriginCopyAheadOfTheLocalBranchGivesTheOriginForkPoint() async throws {
        let (project, first) = try project()
        defer { project.remove() }
        try project.git("checkout", "-q", "--detach", "main")
        try project.write("fetched\n", to: "fetched.txt")
        let fetched = try project.commit("Fetched")
        try project.git("update-ref", "refs/remotes/origin/main", fetched)
        try project.git("checkout", "-q", "-b", "feature")
        try project.write("feature\n", to: "feature.txt")
        try project.commit("Feature")
        #expect(try project.rev("main") == first)

        #expect(try await resolver.resolve(in: project.root, flag: nil, recorded: "main") == ResolvedBase(name: "main", forkPoint: fetched))
        // `--base main` is taken exactly as given: the local branch alone.
        #expect(try await resolver.resolve(in: project.root, flag: "main", recorded: nil) == ResolvedBase(name: "main", forkPoint: first))
    }

    @Test func aRecordedRemoteBranchTagOrCommitIsUsedAsItIs() async throws {
        let (project, first) = try project()
        defer { project.remove() }
        try project.git("update-ref", "refs/remotes/origin/develop", first)
        try project.git("tag", "v1", first)
        for recorded in ["origin/develop", "v1", first] {
            let base = try await resolver.resolve(in: project.root, flag: nil, recorded: recorded)
            #expect(base.forkPoint == first)
            #expect(base.name == (recorded == first ? String(first.prefix(9)) : recorded))
        }
    }

    /// A branch that exists only as its origin copy: a clone that never checked `develop` out.
    @Test func aBranchWithOnlyAnOriginCopyIsMeasuredAgainstThatCopy() async throws {
        let (project, first) = try project()
        defer { project.remove() }
        try project.git("update-ref", "refs/remotes/origin/develop", first)
        #expect(try await resolver.resolve(in: project.root, flag: nil, recorded: "develop") == ResolvedBase(name: "develop", forkPoint: first))
    }

    @Test func aRecordedRefThatIsGoneFallsBackToTheDefaultBranch() async throws {
        let (project, first) = try project()
        defer { project.remove() }
        #expect(try await resolver.resolve(in: project.root, flag: nil, recorded: "deleted-branch") == ResolvedBase(name: "main", forkPoint: first))
    }

    @Test func theDefaultBranchIsWhereOriginHeadPointsThenMainThenMaster() async throws {
        let (project, first) = try project()
        defer { project.remove() }
        try project.git("branch", "trunk", "work")
        try project.git("update-ref", "refs/remotes/origin/trunk", "work")
        try project.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
        #expect(try await resolver.resolve(in: project.root, flag: nil, recorded: nil).name == "trunk")

        try project.git("symbolic-ref", "--delete", "refs/remotes/origin/HEAD")
        #expect(try await resolver.resolve(in: project.root, flag: nil, recorded: nil) == ResolvedBase(name: "main", forkPoint: first))

        try project.git("branch", "-m", "main", "master")
        #expect(try await resolver.resolve(in: project.root, flag: nil, recorded: nil) == ResolvedBase(name: "master", forkPoint: first))
    }

    @Test func noBaseToBeFoundIsAUsageErrorThatNamesTheFlag() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        try project.git("branch", "-m", "main", "trunk")
        let error = await usage { try await resolver.resolve(in: project.root, flag: nil, recorded: nil) }
        #expect(error?.message == "no base to measure the change against: this repository has no main or master branch, and origin/HEAD is not set")
        #expect(error?.next == "pass --base <ref>, or --all to cover the whole project")
    }

    @Test func aBaseGitDoesNotKnowIsAUsageError() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        let error = await usage { try await resolver.resolve(in: project.root, flag: "nosuch", recorded: "main") }
        #expect(error?.message == "git does not know the ref 'nosuch'")
        #expect(error?.next == "pass --base a branch, a tag, or a commit that `git rev-parse` accepts")
    }

    @Test func aBaseWithNoHistoryInCommonIsAUsageError() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        try project.git("checkout", "-q", "--orphan", "island")
        try project.commit("Island")
        let error = await usage { try await resolver.resolve(in: project.root, flag: nil, recorded: nil) }
        #expect(error?.message == "HEAD and main have no commit in common")
        #expect(error?.next?.contains("--base") == true && error?.next?.contains("--all") == true)
    }

    @Test func aRepositoryWithNoCommitsIsAUsageError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-empty-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try TempProject.git(["init", "-q", "-b", "main"], in: root)
        let error = await usage { try await resolver.resolve(in: root, flag: nil, recorded: nil) }
        #expect(error?.message == "this repository has no commits yet, so there is no change to measure")
        #expect(error?.next?.contains("--all") == true)
    }

    @Test func aCheckoutOnNoBranchIsMeasuredFromItsCommit() async throws {
        let (project, first) = try project()
        defer { project.remove() }
        try project.git("checkout", "-q", "--detach")
        #expect(try await resolver.resolve(in: project.root, flag: nil, recorded: nil) == ResolvedBase(name: "main", forkPoint: first))
    }

    /// In the main checkout on `main`, the fork point is HEAD: the change is what is uncommitted.
    @Test func onTheBaseBranchItselfTheForkPointIsHead() async throws {
        let (project, _) = try project()
        defer { project.remove() }
        try project.git("checkout", "-q", "main")
        let head = try project.rev("HEAD")
        #expect(try await resolver.resolve(in: project.root, flag: nil, recorded: nil) == ResolvedBase(name: "main", forkPoint: head))
    }
}
