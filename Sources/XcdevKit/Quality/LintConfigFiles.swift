import Foundation

/// Finds the files SwiftLint reads its rules from when it lints some of a worktree's files.
struct LintConfigFiles {
    /// Where SwiftLint keeps its copy of a `parent_config` that is a URL, under the folder it runs in.
    static let cacheFolder = ".swiftlint/RemoteConfigCache"
    static let referenceKeys = ["parent_config", "child_config"]
    static let includedKey = "included"

    let worktreeRoot: String

    /// Paths relative to the worktree root, in order: `.swiftlint.yml` in the root and in each folder on the way
    /// to one of `files`, each file a `--config` in `args` names, and each file one of those names as its parent
    /// or child config, followed until none is left. A file that is not there is left out, and so is one that a
    /// relative path leaves the worktree to reach. Throws `config_invalid` for an absolute path in a `--config`,
    /// in a `parent_config` or `child_config`, or in `included` (see `refusal`).
    func paths(for files: [String], args: [String]) throws -> [String] {
        var found = Set<String>()
        var waiting = nested(for: files) + (try named(in: args))
        while let path = waiting.popLast() {
            guard !found.contains(path), let text = try? String(contentsOfFile: worktreeRoot + "/" + path, encoding: .utf8) else {
                continue
            }
            found.insert(path)
            waiting += try referenced(by: text, at: path)
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
    /// folder it runs in, which stands for the worktree root. Throws for an absolute path; one that leaves the
    /// worktree is left out.
    func named(in args: [String]) throws -> [String] {
        var paths: [String] = []
        for (index, argument) in args.enumerated() {
            if argument == "--config", args.indices.contains(index + 1) { paths.append(args[index + 1]) }
            if argument.hasPrefix("--config=") { paths.append(String(argument.dropFirst("--config=".count))) }
        }
        if let absolute = paths.first(where: Self.isAbsolute) { throw Self.refusal("lint.args: --config \(absolute)") }
        return paths.compactMap { Self.normalized($0, from: "") }
    }

    /// The parent and child configs a config file names, read from the file's own folder. A URL names no file in
    /// the worktree, so it finds nothing here and is left to SwiftLint. Throws for an absolute path in either, or
    /// in the file's `included`; one that leaves the worktree is left out.
    func referenced(by text: String, at path: String) throws -> [String] {
        guard let settings = SwiftLintConfig.settings(text) else { return [] }
        for key in Self.referenceKeys + [Self.includedKey] {
            let values = key == Self.includedKey ? SwiftLintConfig.paths(key, in: settings) : [settings[key]?.string].compactMap { $0 }
            if let absolute = values.first(where: Self.isAbsolute) { throw Self.refusal("\(path): \(key): \(absolute)") }
        }
        let folder = path.split(separator: "/").dropLast().joined(separator: "/")
        return Self.referenceKeys.compactMap { settings[$0]?.string }.compactMap { Self.normalized($0, from: folder) }
    }

    /// `reference` read from `folder`, as a path relative to the worktree root with no `.` or `..` in it. Nil for one
    /// that leaves the worktree, and for an absolute path (callers refuse those before they ask).
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

    /// SwiftLint follows an absolute path out of the folder it runs in and lints the files beside it.
    static func isAbsolute(_ path: String) -> Bool { path.hasPrefix("/") }

    static func refusal(_ subject: String) -> XcdError {
        XcdError(.configInvalid, subject + " is an absolute path, which xcd lint cannot follow",
                 next: "use a path relative to the worktree: xcd lints copies of the files in a scratch folder, and SwiftLint would lint "
                    + "the files beside an absolute path instead. A project that needs the path sets lint.run to its own lint command")
    }
}
