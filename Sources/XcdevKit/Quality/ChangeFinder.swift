import Foundation

/// A Swift file a quality command covers.
public struct ScopedFile: Sendable, Equatable {
    /// Relative to the worktree root.
    public let path: String
    /// Where the file was at the fork point. Nil for a file the change added, and for every file under `--all`.
    public let basePath: String?

    public init(path: String, basePath: String?) {
        self.path = path
        self.basePath = basePath
    }
}

/// Finds the Swift files in scope by asking git, so an ignored folder such as `.xcdev/` is never walked.
public struct ChangeFinder: Sendable {
    public let runner: any ProcessRunning

    public init(runner: any ProcessRunning) { self.runner = runner }

    /// The Swift files the working tree changed against `forkPoint`: committed, staged, and unstaged work, and
    /// new files git does not track yet. Deleted files are left out, and a renamed file keeps its old path.
    public func changed(in root: String, since forkPoint: String) async throws -> [ScopedFile] {
        Self.swiftFiles(try await changes(in: root, since: forkPoint), in: root)
    }

    /// The same, of every kind of file: the files whose warnings a build result lists.
    public func touched(in root: String, since forkPoint: String) async throws -> [String] {
        Self.regularFiles(try await changes(in: root, since: forkPoint), in: root).map(\.path)
    }

    func changes(in root: String, since forkPoint: String) async throws -> [ScopedFile] {
        let status = try await records(["diff", "--name-status", "-M", "-z", forkPoint], in: root)
        let untracked = try await records(["ls-files", "--others", "--exclude-standard", "-z"], in: root)
        return Self.parse(nameStatus: status) + untracked.map { ScopedFile(path: $0, basePath: nil) }
    }

    /// Every Swift file git knows in the worktree: tracked, or untracked and not ignored.
    public func everyFile(in root: String) async throws -> [ScopedFile] {
        let known = try await records(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], in: root)
        return Self.swiftFiles(known.map { ScopedFile(path: $0, basePath: nil) }, in: root)
    }

    /// git's output with `-z`: records that end in NUL, with every path as it is on disk.
    func records(_ arguments: [String], in root: String) async throws -> [String] {
        try await runner.runChecked(.git(arguments, in: root)).stdoutString.split(separator: "\0").map(String.init)
    }

    /// `git diff --name-status -z`: a status, then one path, or two for a rename (the old one first). A deleted
    /// file is listed like a modified one here; `swiftFiles` drops it, since it is not on disk, or is there only
    /// through a link.
    static func parse(nameStatus records: [String]) -> [ScopedFile] {
        var files: [ScopedFile] = []
        var rest = records[...]
        while let status = rest.popFirst(), let first = rest.popFirst() {
            let moved = status.hasPrefix("R") || status.hasPrefix("C")
            guard let path = moved ? rest.popFirst() : first else { break }
            files.append(ScopedFile(path: path, basePath: status.hasPrefix("A") ? nil : first))
        }
        return files
    }

    /// The regular files among `files` that end in `.swift`, each once, in path order.
    static func swiftFiles(_ files: [ScopedFile], in root: String) -> [ScopedFile] {
        regularFiles(files.filter { $0.path.hasSuffix(".swift") }, in: root)
    }

    /// The regular files among `files`, each once, in path order. A link is not a regular file, and a file under a
    /// folder that is a link is not the worktree's: git lists a tracked folder that was replaced by a link as files
    /// that were deleted, while their paths lead through the link to whatever is there.
    static func regularFiles(_ files: [ScopedFile], in root: String) -> [ScopedFile] {
        var seen = Set<String>()
        var linked = LinkedFolders(root: root)
        return files.filter { file in
            guard seen.insert(file.path).inserted, !linked.hold(file.path) else { return false }
            let values = try? URL(fileURLWithPath: root + "/" + file.path).resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }.sorted { $0.path < $1.path }
    }
}

/// Which folders of a worktree are links, each looked at once.
struct LinkedFolders {
    let root: String
    /// Each folder asked about so far, by its full path, and whether it is a link.
    private var links: [String: Bool] = [:]

    init(root: String) { self.root = root }

    /// Whether the file at `path`, relative to the root, lies under a folder that is a link, so that its path leads
    /// out of the folder git knows it in. Each folder on the way is looked at. The path with its links resolved is
    /// not compared with the path as git gave it: resolving also spells every name as the disk has it, which is
    /// another case than git's after a rename that changed only the case.
    mutating func hold(_ path: String) -> Bool {
        var folder = root
        for name in path.split(separator: "/").dropLast() {
            folder += "/" + name
            if isLink(folder) { return true }
        }
        return false
    }

    private mutating func isLink(_ folder: String) -> Bool {
        if let known = links[folder] { return known }
        let values = try? URL(fileURLWithPath: folder, isDirectory: false).resourceValues(forKeys: [.isSymbolicLinkKey])
        let isLink = values?.isSymbolicLink == true
        links[folder] = isLink
        return isLink
    }
}
