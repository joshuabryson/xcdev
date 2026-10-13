import Foundation

/// A scratch folder that SwiftLint is run in, outside the worktree. It holds copies of the
/// Swift files to lint and of the project's lint config, and nothing in it is a link, so nothing SwiftLint does
/// there can reach the worktree. In place, SwiftLint would walk `.xcdev/` and lint files the config leaves out.
public struct LintFolder: Sendable {
    public let root: String
    /// The handler a signal that ends xcd runs, and this folder's cleanup there. Nil for a folder made without one.
    private let guarded: (interrupts: Interrupts, cleanup: Interrupts.Cleanup)?

    /// A new, empty folder under the system's temporary directory. With `interrupts`, a signal that ends xcd removes
    /// the folder, and from then on nothing is made or written here: the handler removes the folder once, and xcd
    /// exits before anything could remove what a later write brought back. The cleanup is registered before the
    /// folder is made, so there is no moment at which the folder is there and the handler does not know it.
    public static func create(removedBy interrupts: Interrupts? = nil, under parent: String = NSTemporaryDirectory()) throws -> LintFolder {
        let root = (parent as NSString).appendingPathComponent("xcd-lint-" + UUID().uuidString)
        let folder = LintFolder(root: root, guarded: interrupts.map { ($0, $0.addCleanup { Disk.remove(root) }) })
        do {
            try folder.writing { try Disk.makeFolder(root) }
        } catch {
            folder.remove()
            throw error
        }
        return folder
    }

    /// Writes a file at `path` inside the folder, making the folders on the way to it.
    public func write(_ contents: Data, to path: String) throws {
        let full = root + "/" + path
        try writing {
            try Disk.makeFolder((full as NSString).deletingLastPathComponent)
            try contents.write(to: URL(fileURLWithPath: full))
        }
    }

    /// Runs `work` as one write of the handler's: it waits for a write under way before it removes the folder, and
    /// lets none start afterwards. Throws when the handler has fired, and what `work` throws.
    private func writing(_ work: () throws -> Void) throws {
        guard let interrupts = guarded?.interrupts else { return try work() }
        var failure: (any Error)?
        let ran = interrupts.perform {
            do { try work() } catch { failure = error }
        }
        if let failure { throw failure }
        guard ran else { throw XcdError(.subprocessFailed, "xcd was interrupted, so nothing more was written to its lint folder") }
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
        if let guarded { guarded.interrupts.removeCleanup(guarded.cleanup) }
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
