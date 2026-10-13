import Foundation

/// Finds the files SwiftLint reads its rules from when it lints some of a worktree's files.
struct LintConfigFiles {
    /// Where SwiftLint keeps its copy of a `parent_config` that is a URL, under the folder it runs in.
    static let cacheFolder = ".swiftlint/RemoteConfigCache"
    static let referenceKeys = ["parent_config", "child_config"]

    let worktreeRoot: String

    /// Paths relative to the worktree root, in order: `.swiftlint.yml` in the root and in each folder on the way
    /// to one of `files`, each file a `--config` in `args` names, and each file one of those names as its parent
    /// or child config, followed until none is left. A file that is not there is left out, and so is one that a
    /// path leaves the worktree to reach.
    func paths(for files: [String], args: [String]) -> [String] {
        var found = Set<String>()
        var waiting = nested(for: files) + named(in: args)
        while let path = waiting.popLast() {
            guard !found.contains(path), let text = try? String(contentsOfFile: worktreeRoot + "/" + path, encoding: .utf8) else {
                continue
            }
            found.insert(path)
            waiting += referenced(by: text, at: path)
        }
        return found.sorted()
    }

    /// SwiftLint's nested configs: one per folder from the root down to each file's own folder.
    func nested(for files: [String]) -> [String] {
        var folders: Set<String> = [""]
        for file in files {
            var parts = file.split(separator: "/").dropLast()
            while !parts.isEmpty {
                folders.insert(parts.joined(separator: "/"))
                parts = parts.dropLast()
            }
        }
        return folders.map { $0.isEmpty ? SwiftLintConfig.fileName : $0 + "/" + SwiftLintConfig.fileName }
    }

    /// The values of `--config`, written as `--config <path>` or `--config=<path>`. SwiftLint reads them from the
    /// folder it runs in, which stands for the worktree root.
    func named(in args: [String]) -> [String] {
        var paths: [String] = []
        for (index, argument) in args.enumerated() {
            if argument == "--config", args.indices.contains(index + 1) { paths.append(args[index + 1]) }
            if argument.hasPrefix("--config=") { paths.append(String(argument.dropFirst("--config=".count))) }
        }
        return paths.compactMap { Self.normalized($0, from: "") }
    }

    /// The parent and child configs a config file names, read from the file's own folder. A URL names no file in
    /// the worktree, so it finds nothing here and is left to SwiftLint.
    func referenced(by text: String, at path: String) -> [String] {
        guard let settings = SwiftLintConfig.settings(text) else { return [] }
        let folder = path.split(separator: "/").dropLast().joined(separator: "/")
        return Self.referenceKeys.compactMap { settings[$0]?.string }.compactMap { Self.normalized($0, from: folder) }
    }

    /// `reference` read from `folder`, as a path relative to the worktree root with no `.` or `..` in it. Nil for an
    /// absolute path and for one that leaves the worktree.
    static func normalized(_ reference: String, from folder: String) -> String? {
        guard !reference.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in (folder + "/" + reference).split(separator: "/") where part != "." {
            if part != ".." {
                parts.append(part)
            } else if parts.popLast() == nil {
                return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }
}
