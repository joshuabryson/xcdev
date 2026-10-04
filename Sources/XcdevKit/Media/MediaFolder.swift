import Foundation

/// The folder captures go to: `ui.media.dir` with its placeholders expanded.
public struct MediaFolder: Sendable, Equatable {
    /// Absolute.
    public let directory: String
    /// The main checkout, which a relative template starts at.
    public let projectRoot: String
    /// What `.gitignore` in the main checkout should list for this folder, relative to it with a trailing `/`: the
    /// template's fixed prefix, or its first expanded folder when it starts with a placeholder. Nil when the folder is
    /// outside the checkout (or is the checkout).
    public let ignoreEntry: String?

    public init(directory: String, projectRoot: String, ignoreEntry: String? = nil) {
        self.directory = directory
        self.projectRoot = projectRoot
        self.ignoreEntry = ignoreEntry
    }

    /// `device` nil (a context with no device) expands {device} to "nodevice".
    public static func resolve(template: String, projectRoot: String, worktreeRoot: String, worktreeName: String,
                               device: String?, home: String = NSHomeDirectory()) -> MediaFolder {
        let branch: [String]
        switch GitHead.read(worktreeRoot: worktreeRoot) {
        case .branch(let name)?: branch = components(name)
        case .detached(let commit)?: branch = [sanitize("detached-" + String(commit.prefix(12)))].compactMap { $0 }
        case nil: branch = []
        }
        let values: [String: String] = [
            "project": sanitize(URL(fileURLWithPath: projectRoot).lastPathComponent) ?? "project",
            "worktree": sanitize(worktreeName) ?? "worktree",
            "branch": branch.isEmpty ? "nobranch" : branch.joined(separator: "/"),
            "device": device.flatMap(sanitize) ?? "nodevice",
        ]
        var expanded = template
        for (name, value) in values { expanded = expanded.replacingOccurrences(of: "{\(name)}", with: value) }
        let directory = absolute(expanded, projectRoot: projectRoot, home: home)
        // The template's fixed prefix; with none (or only the checkout itself), the first expanded folder.
        let inside = projectRoot + "/"
        var entry: String?
        if directory.hasPrefix(inside) {
            if let fixed = root(template: template, projectRoot: projectRoot, home: home), fixed != projectRoot {
                if fixed.hasPrefix(inside) { entry = String(fixed.dropFirst(inside.count)) + "/" }
            } else if let first = directory.dropFirst(inside.count).split(separator: "/").first {
                entry = String(first) + "/"
            }
        }
        return MediaFolder(directory: directory, projectRoot: projectRoot, ignoreEntry: entry)
    }

    /// The fixed part of `template`, before its first placeholder, as an absolute path: the folder that holds every
    /// capture (for disk usage). Nil when the template starts with a placeholder.
    public static func root(template: String, projectRoot: String, home: String = NSHomeDirectory()) -> String? {
        let fixed = template.split(separator: "/", omittingEmptySubsequences: false).prefix { !$0.contains("{") }
        let joined = fixed.joined(separator: "/")
        guard !joined.isEmpty, joined != "~" || template == "~" else { return nil }
        return absolute(joined, projectRoot: projectRoot, home: home)
    }

    /// A new capture's path: `<directory>/<yyyyMMdd-HHmmss>-<device>-<kind>.<ext>`, suffixed if taken. Creates the folder.
    public func newFile(device: String, kind: String, ext: String, now: Date) -> String {
        WorktreePaths(root: directory).newArtifact(in: directory, kind: "\(Self.sanitize(device) ?? "nodevice")-\(kind)",
                                                   ext: ext, now: now)
    }

    /// Makes sure `.gitignore` in the main checkout lists `ignoreEntry`. Returns the entry it added, nil when there is
    /// none or it was already listed.
    @discardableResult
    public func ensureIgnored() throws -> String? {
        guard let ignoreEntry, directory.hasPrefix(projectRoot + "/") else { return nil }
        return try Gitignore.ensure([ignoreEntry], in: projectRoot, comment: "screenshots and recordings").first
    }

    /// A name made safe as one folder: anything but letters, digits, `.`, `_`, and `-` becomes `-`. Nil for an empty
    /// result, `.`, or `..`.
    static func sanitize(_ name: String) -> String? {
        let safe = String(name.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar) ? Character(scalar) : "-"
        })
        return safe.isEmpty || safe == "." || safe == ".." ? nil : safe
    }

    /// A branch name as nested folders, each sanitized, with empty, `.`, and `..` parts dropped.
    static func components(_ branch: String) -> [String] {
        branch.split(separator: "/").compactMap { sanitize(String($0)) }
    }

    static func absolute(_ path: String, projectRoot: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return (home + path.dropFirst(1) as NSString).standardizingPath }
        if path.hasPrefix("/") { return (path as NSString).standardizingPath }
        return ((projectRoot + "/" + path) as NSString).standardizingPath
    }
}
