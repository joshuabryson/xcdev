import Foundation

/// A scratch folder that SwiftLint is run in, outside the worktree. It holds copies of the
/// Swift files to lint and of the project's lint config, and nothing in it is a link, so nothing SwiftLint does
/// there can reach the worktree. In place, SwiftLint would walk `.xcdev/` and lint files the config leaves out.
public struct LintFolder: Sendable {
    public let root: String

    /// A new, empty folder under the system's temporary directory.
    public static func create() throws -> LintFolder {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("xcd-lint-" + UUID().uuidString)
        try Disk.makeFolder(root)
        return LintFolder(root: root)
    }

    /// Writes a file at `path` inside the folder, making the folders on the way to it.
    public func write(_ contents: Data, to path: String) throws {
        let full = root + "/" + path
        try Disk.makeFolder((full as NSString).deletingLastPathComponent)
        try contents.write(to: URL(fileURLWithPath: full))
    }

    /// Copies the lint config that applies to `files` (paths relative to the worktree root) as it is in the
    /// working tree, and SwiftLint's cache of remote configs when the worktree has one. `args` are the project's
    /// extra SwiftLint arguments, which may name config files.
    public func copyConfig(from worktreeRoot: String, for files: [String], args: [String]) throws {
        let cache = Disk.files(under: worktreeRoot + "/" + LintConfigFiles.cacheFolder).map { LintConfigFiles.cacheFolder + "/" + $0 }
        for path in LintConfigFiles(worktreeRoot: worktreeRoot).paths(for: files, args: args) + cache {
            try write(try Data(contentsOf: URL(fileURLWithPath: worktreeRoot + "/" + path)), to: path)
        }
    }

    public func remove() {
        Disk.remove(root)
    }

    /// The path inside the folder of a file SwiftLint reported: it gives absolute paths, and drops a leading
    /// `/private` from them. Nil for a path that is not in the folder.
    public func path(of reported: String) -> String? {
        let base = Paths.canonical(root) + "/"
        let full = Paths.canonical(reported)
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : nil
    }
}
