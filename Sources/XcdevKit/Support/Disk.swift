import Foundation

/// The folder operations a scratch folder needs. Each call uses a file manager of its own, since nothing is kept
/// from one call to the next.
enum Disk {
    /// Makes the folder and the folders on the way to it. One that is already there is left as it is.
    static func makeFolder(_ path: String) throws {
        try FileManager().createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// Deletes the folder and what it holds. Nothing happens when it is not there.
    static func remove(_ path: String) {
        try? FileManager().removeItem(atPath: path)
    }

    /// Renames the file or folder to `destination`, which must not exist.
    static func move(_ path: String, to destination: String) throws {
        try FileManager().moveItem(atPath: path, toPath: destination)
    }

    /// The regular files under the folder, relative to it, in order. Empty when it is not a folder. Links are left out.
    static func files(under path: String) -> [String] {
        let below = (try? FileManager().subpathsOfDirectory(atPath: path)) ?? []
        return below.sorted().filter { isRegularFile(path + "/" + $0) }
    }

    /// The names of what the folder holds, one level down only, in order. Empty when it is not a folder.
    static func names(in path: String) -> [String] {
        ((try? FileManager().contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    /// Whether something is at `path`. A link is followed, so one that leads nowhere is not there.
    static func exists(_ path: String) -> Bool {
        access(path, F_OK) == 0
    }

    /// `path` with its links resolved and every name as the disk spells it, or nil when nothing is there.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isRegularFile(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// Whether `path` is a file this process may run. A link is followed, as Homebrew's commands are links.
    static func isExecutable(_ path: String) -> Bool {
        access(path, X_OK) == 0 && isRegularFile(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    /// When the file at `path` last changed, or nil when nothing is there.
    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager().attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
