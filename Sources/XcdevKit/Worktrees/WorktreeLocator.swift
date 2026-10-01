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
        let top = try await runner.run(.git(["rev-parse", "--show-toplevel"], in: directory))
        guard top.succeeded else {
            throw XcdError(.notInProject, "\(directory) is not inside a git repository",
                           next: "cd into a project that has a .xcdev.yml (or run `git init`, then `xcd init`)")
        }
        let common = try await runner.runChecked(.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory))
        let commonDir = common.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectRoot = URL(fileURLWithPath: commonDir).deletingLastPathComponent().path
        let worktreeRoot = top.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProjectLocation(projectRoot: Paths.canonical(projectRoot), worktreeRoot: Paths.canonical(worktreeRoot))
    }
}
