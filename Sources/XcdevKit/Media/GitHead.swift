import Foundation

/// What a checkout has checked out, read from its git files without running git.
public enum GitHead {
    public enum Head: Sendable, Equatable {
        case branch(String)
        case detached(commit: String)
    }

    /// The HEAD of the checkout at `worktreeRoot`: `.git` is a folder in the main checkout and a `gitdir: <path>` file
    /// in a linked worktree. Nil when there is no readable HEAD.
    public static func read(worktreeRoot: String) -> Head? {
        let dotGit = worktreeRoot + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        let gitDir: String
        if isDirectory.boolValue {
            gitDir = dotGit
        } else {
            guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDir = path.hasPrefix("/") ? path : ((worktreeRoot + "/" + path) as NSString).standardizingPath
        }
        guard let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return nil }
        if head.hasPrefix("ref:") {
            let ref = head.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
            return .branch(ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref)
        }
        return .detached(commit: head)
    }
}
