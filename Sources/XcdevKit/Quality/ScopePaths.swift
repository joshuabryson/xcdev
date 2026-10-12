import Foundation

/// The paths given to a quality command, which narrow its scope to those files and folders.
public struct ScopePaths: Sendable, Equatable {
    /// Each path relative to the worktree root, with no slash at its end. The root itself is the empty string.
    public let prefixes: [String]

    /// Whether no path was given.
    public var isEmpty: Bool { prefixes.isEmpty }

    /// A path is read from `directory`, the current directory, when that is inside the worktree. Otherwise (a
    /// command run with `--worktree` from somewhere else) it is read from the worktree root. A path that is not
    /// in the worktree, or that names nothing, is a `usage` error.
    public init(_ paths: [String], from directory: String, in worktreeRoot: String) throws {
        let root = Paths.canonical(worktreeRoot)
        let current = Paths.canonical(directory)
        let start = current == root || current.hasPrefix(root + "/") ? current : root
        prefixes = try paths.map { path in
            let full = Paths.canonical(path.hasPrefix("/") ? path : start + "/" + path)
            guard full == root || full.hasPrefix(root + "/") else {
                throw XcdError(.usage, "'\(path)' is outside this worktree", next: "name files or folders inside \(root)")
            }
            guard (try? URL(fileURLWithPath: full).checkResourceIsReachable()) == true else {
                throw XcdError(.usage, "'\(path)' does not exist", next: "name files or folders inside \(root)")
            }
            return String(full.dropFirst(root.count + 1))
        }
    }

    /// The files that are one of the paths or lie under one. Every file when no path was given.
    public func narrow(_ files: [ScopedFile]) -> [ScopedFile] {
        guard !isEmpty else { return files }
        return files.filter { file in
            prefixes.contains { $0.isEmpty || file.path == $0 || file.path.hasPrefix($0 + "/") }
        }
    }
}
