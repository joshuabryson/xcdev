import Foundation

/// The ref a change is measured against, and the commit where the work left it.
public struct ResolvedBase: Sendable, Equatable {
    /// As a result names it (`base=main`). A commit is shortened to nine characters.
    public let name: String
    /// The commit the working tree is compared with.
    public let forkPoint: String

    public init(name: String, forkPoint: String) {
        self.name = name
        self.forkPoint = forkPoint
    }
}

public struct BaseResolver: Sendable {
    public let runner: any ProcessRunning

    public init(runner: any ProcessRunning) { self.runner = runner }

    /// `flag` is `--base`, taken exactly as given. Without it: the worktree's recorded base, then the branch
    /// `origin/HEAD` points to, then `main`, then `master`, whichever is there first. A branch found that way is
    /// measured from the nearer of its local and `origin` copies.
    public func resolve(in root: String, flag: String?, recorded: String?) async throws -> ResolvedBase {
        let git = GitQuery(runner: runner, directory: root)
        guard try await git.commit("HEAD") != nil else {
            throw XcdError(.usage, "this repository has no commits yet, so there is no change to measure",
                           next: "pass --all to cover the whole project")
        }
        if let flag {
            guard try await git.commit(flag) != nil else {
                throw XcdError(.usage, "git does not know the ref '\(flag)'",
                               next: "pass --base a branch, a tag, or a commit that `git rev-parse` accepts")
            }
            return try await fork(from: [flag], named: flag, git)
        }
        for name in [recorded, try await originHead(git), "main", "master"].compactMap({ $0 }) {
            let refs = try await candidates(for: name, git)
            if !refs.isEmpty { return try await fork(from: refs, named: name, git) }
        }
        throw XcdError(.usage, "no base to measure the change against: this repository has no main or master branch, and origin/HEAD is not set",
                       next: "pass --base <ref>, or --all to cover the whole project")
    }

    /// The branch `origin/HEAD` points to, without its remote: `main` for `origin/main`.
    func originHead(_ git: GitQuery) async throws -> String? {
        guard let head = try await git.line(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]) else { return nil }
        return head.hasPrefix("origin/") ? String(head.dropFirst("origin/".count)) : head
    }

    /// The refs that stand for `name`: a local branch and its `origin` copy, the ref itself when it is a remote
    /// branch, a tag, or a commit, or the `origin` copy of a branch this repository has no local copy of. Empty
    /// when git knows none of them.
    func candidates(for name: String, _ git: GitQuery) async throws -> [String] {
        let origin = { (branch: String) in "refs/remotes/origin/" + branch }
        if let full = try await git.fullName(name), full.hasPrefix("refs/heads/") {
            let copy = origin(String(full.dropFirst("refs/heads/".count)))
            return try await git.commit(copy) == nil ? [full] : [full, copy]
        }
        if try await git.commit(name) != nil { return [name] }
        return try await git.commit(origin(name)) == nil ? [] : [origin(name)]
    }

    /// Where HEAD left `refs`. With two refs, git gives the commit nearer to HEAD. In a shallow clone git answers
    /// "no common commit" also when the clone's cut hides the one they share, so that clone is named.
    func fork(from refs: [String], named name: String, _ git: GitQuery) async throws -> ResolvedBase {
        guard let commit = try await git.line(["merge-base", "HEAD"] + refs) else {
            guard try await !git.isShallow() else {
                throw XcdError(.usage, "HEAD and \(name) have no commit in common in this shallow clone; its cut-off history may hide the one they share",
                               next: "deepen the clone with `git fetch --unshallow` (or `git fetch --deepen=<n>`) and run the command again, "
                                   + "or pass --all to cover the whole project")
            }
            throw XcdError(.usage, "HEAD and \(name) have no commit in common",
                           next: "pass --base a ref this work was made from, or --all to cover the whole project")
        }
        let isCommit = name.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
        return ResolvedBase(name: isCommit ? String(name.prefix(9)) : name, forkPoint: commit)
    }
}
