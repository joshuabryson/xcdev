import Foundation

public struct ProjectLocation: Sendable, Equatable {
    /// Canonical path of the main checkout.
    public let projectRoot: String
    /// Canonical path of the checkout containing the working directory.
    public let worktreeRoot: String

    public init(projectRoot: String, worktreeRoot: String) {
        self.projectRoot = projectRoot
        self.worktreeRoot = worktreeRoot
    }

    public var isMain: Bool { projectRoot == worktreeRoot }
    public var projectName: String { URL(fileURLWithPath: projectRoot).lastPathComponent }
}

public struct WorktreeLocator: Sendable {
    public let runner: any ProcessRunning

    public init(runner: any ProcessRunning) { self.runner = runner }

    public func locate(from directory: String) async throws -> ProjectLocation {
        let invocation = Invocation.git(["rev-parse", "--show-toplevel"], in: directory)
        let top = try await runner.run(invocation)
        guard top.succeeded else { throw Self.failure(invocation, top, from: directory) }
        let common = try await runner.runChecked(.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory))
        let commonDir = common.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectRoot = URL(fileURLWithPath: commonDir).deletingLastPathComponent().path
        let worktreeRoot = top.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProjectLocation(projectRoot: Paths.canonical(projectRoot), worktreeRoot: Paths.canonical(worktreeRoot))
    }

    /// Why git found no project from `directory`. Outside a project only when git
    /// says so and no `.git` is in the directory or above it: git says the same of a repository whose HEAD is
    /// damaged. A checkout whose `.git` file names a repository that is gone is a worktree whose main checkout was
    /// moved or deleted. Anything else is git's failure.
    static func failure(_ invocation: Invocation, _ output: ProcessOutput, from directory: String) -> XcdError {
        let entry = nearestGitEntry(from: directory)
        if entry == nil, output.stderrString.contains("not a git repository (or any of the parent directories)") {
            return XcdError(.notInProject, "\(directory) is not inside a git repository",
                            next: "cd into a project that has a .xcdev.yml (or run `git init`, then `xcd init`)")
        }
        var error = XcdError.subprocess(invocation, output)
        if let entry, let gone = missingRepository(of: entry) {
            error.message = "this checkout is a git worktree, and its repository is no longer at \(gone)"
            error.next = "ask the user where the main checkout is now; `git worktree repair` run there reconnects this checkout. "
                + "If it was deleted, this checkout cannot be repaired"
        }
        return error
    }

    /// The `.git` folder or file in `directory` or the nearest folder above it that has one.
    static func nearestGitEntry(from directory: String) -> String? {
        var folder = URL(fileURLWithPath: directory).standardizedFileURL
        while true {
            let entry = folder.appendingPathComponent(".git").path
            var info = stat()
            if lstat(entry, &info) == 0 { return entry }
            guard folder.path != "/" else { return nil }
            folder.deleteLastPathComponent()
        }
    }

    /// The repository a `.git` file names (`gitdir: <path>`), when it is not there. Nil for a `.git` folder, and for
    /// a `.git` file whose repository is there.
    static func missingRepository(of entry: String) -> String? {
        guard let text = try? String(contentsOfFile: entry, encoding: .utf8), text.hasPrefix("gitdir: ") else { return nil }
        let named = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let path = named.hasPrefix("/") ? named : ((entry as NSString).deletingLastPathComponent as NSString).appendingPathComponent(named)
        return Disk.exists(path) ? nil : named
    }
}
