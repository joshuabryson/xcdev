import Foundation

/// A folder of xcd's own under the system's temporary directory, outside every worktree, for what a tool has to be
/// handed as files. It is removed when the command ends, also when it is interrupted.
public struct ScratchFolder: Sendable {
    public let root: String
    /// What the folder is for, `lint` or `format`: part of its name, and of what an interrupted write says.
    let purpose: String
    /// The handler a signal that ends xcd runs, and this folder's cleanup there. Nil for a folder made without one.
    private let guarded: (interrupts: Interrupts, cleanup: Interrupts.Cleanup)?

    /// A new, empty folder named `xcd-<purpose>-…`. With `interrupts`, a signal that ends xcd removes the folder, and
    /// from then on nothing is made or written here: the handler removes the folder once, and xcd exits before
    /// anything could remove what a later write brought back. The cleanup is registered before the folder is made,
    /// so there is no moment at which the folder is there and the handler does not know it.
    public static func create(for purpose: String, removedBy interrupts: Interrupts? = nil,
                              under parent: String = NSTemporaryDirectory()) throws -> ScratchFolder {
        let root = (parent as NSString).appendingPathComponent("xcd-\(purpose)-" + UUID().uuidString)
        let folder = ScratchFolder(root: root, purpose: purpose, guarded: interrupts.map { ($0, $0.addCleanup { Disk.remove(root) }) })
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
        guard ran else { throw XcdError(.subprocessFailed, "xcd was interrupted, so nothing more was written to its \(purpose) folder") }
    }

    /// Deletes the folder, and takes it off the handler's list.
    public func remove() {
        if let guarded { guarded.interrupts.removeCleanup(guarded.cleanup) }
        Disk.remove(root)
    }
}
