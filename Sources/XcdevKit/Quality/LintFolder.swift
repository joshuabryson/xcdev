import Foundation

/// A scratch folder that SwiftLint is run in, outside the worktree. It holds copies of the
/// Swift files to lint and of the project's lint config, and nothing in it is a link, so nothing SwiftLint does
/// there can reach the worktree. In place, SwiftLint would walk `.xcdev/` and lint files the config leaves out.
public struct LintFolder: Sendable {
    let scratch: ScratchFolder

    public var root: String { scratch.root }

    /// A new, empty folder under the system's temporary directory, which a signal that ends xcd removes when
    /// `interrupts` is given (see `ScratchFolder`).
    public static func create(removedBy interrupts: Interrupts? = nil, under parent: String = NSTemporaryDirectory()) throws -> LintFolder {
        LintFolder(scratch: try ScratchFolder.create(for: "lint", removedBy: interrupts, under: parent))
    }

    /// Writes a file at `path` inside the folder, making the folders on the way to it.
    public func write(_ contents: Data, to path: String) throws {
        try scratch.write(contents, to: path)
    }

    /// Copies the lint config that applies to `files` (paths relative to the worktree root) as it is in the
    /// working tree, and SwiftLint's cache of remote configs when the worktree has one. `args` are the project's
    /// extra SwiftLint arguments, which may name config files. Throws `config_invalid`, before it writes anything,
    /// for a config that holds an absolute path SwiftLint would follow out of the folder.
    public func copyConfig(from worktreeRoot: String, for files: [String], args: [String]) throws {
        let configs = try LintConfigFiles(worktreeRoot: worktreeRoot).paths(for: files, args: args)
        let cache = Disk.files(under: worktreeRoot + "/" + LintConfigFiles.cacheFolder).map { LintConfigFiles.cacheFolder + "/" + $0 }
        for path in configs + cache {
            try write(try Data(contentsOf: URL(fileURLWithPath: worktreeRoot + "/" + path)), to: path)
        }
    }

    /// Deletes the folder, and takes it off the handler's list.
    public func remove() {
        scratch.remove()
    }

    /// The path inside the folder of a file SwiftLint reported: it gives absolute paths, and drops a leading
    /// `/private` from them. Nil for a path that is not in the folder.
    public func path(of reported: String) -> String? {
        let base = Paths.canonical(root) + "/"
        let full = Paths.canonical(reported)
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : nil
    }
}
