import Foundation
import Yams

/// A project's `.swiftlint.yml`, read for one thing: whether SwiftLint looks through xcd's `.xcdev/` folder.
///
/// SwiftLint searches every folder under the one it runs in, hidden ones too. A build that runs it then has it go
/// through the worktree's DerivedData and package checkouts as well: tens of thousands of files on every build, which
/// took minutes in one project against half a second for the project's own sources. The config's `excluded` list
/// keeps it out, as does an `included` list that names only the project's own folders.
public struct SwiftLintConfig: Sendable, Equatable {
    public static let fileName = ".swiftlint.yml"
    /// The folder as `excluded` lists it: relative to the config's folder, which is the worktree's root.
    public static let stateFolder = ".xcdev"
    static let excludedKey = "excluded"

    /// What is wrong when SwiftLint searches the folder, for a warning or a doctor problem.
    public static let problem = "\(fileName) doesn't exclude \(stateFolder)/, so SwiftLint searches xcd's build folder on every run, "
        + "which can add minutes to a build"
    /// What a person does about it.
    public static let byHand = "add `\(stateFolder)` to the `excluded` list in \(fileName)"
    /// What does it for them, in a project that has its .xcdev.yml.
    public static let doctorFix = "run `xcd doctor --fix`"

    public let path: String
    public let text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }

    /// The config in the folder `root`; nil when it has none.
    public static func load(in root: String) -> SwiftLintConfig? {
        let path = root + "/" + fileName
        return (try? String(contentsOfFile: path, encoding: .utf8)).map { SwiftLintConfig(path: path, text: $0) }
    }

    /// Whether SwiftLint, run in the config's folder, looks through `.xcdev/`. A config it can't read counts as none:
    /// SwiftLint warns at most, and carries on with its defaults.
    public var searchesStateFolder: Bool {
        guard let settings = Self.settings(text) else { return true }
        let included = Self.paths("included", in: settings)
        let reached = included.isEmpty || included.contains { Self.isRoot($0) || Self.covers($0) }
        return reached && !Self.paths(Self.excludedKey, in: settings).contains(where: Self.covers)
    }

    /// The config with `.xcdev` added to `excluded` and every other character as it was. Nil when SwiftLint already
    /// stays out, and when the file is laid out in a way this doesn't know how to edit: the result is read back, and
    /// given only if it says what the file said plus the one path.
    public var excludingStateFolder: String? {
        guard searchesStateFolder, let edited = edited(), isThisPlusTheFolder(edited) else { return nil }
        return edited
    }

    /// The problem and what to do about it, in one line. `command` is what adds the entry; it is named only when
    /// this file is one that can be edited.
    public func warning(fixedBy command: String?) -> String {
        let command = excludingStateFolder == nil ? nil : command
        return Self.problem + "; " + (command.map { $0 + ", or " } ?? "") + Self.byHand
    }

    /// Adds `.xcdev` to `excluded` in the file. False, with nothing written, when `excludingStateFolder` is nil.
    public func excludeStateFolder() throws -> Bool {
        guard let edited = excludingStateFolder else { return false }
        try edited.write(toFile: path, atomically: true, encoding: .utf8)
        return true
    }

    /// The top-level settings; empty for an empty file, nil for one that isn't a YAML mapping.
    static func settings(_ yaml: String) -> Node.Mapping? {
        do {
            guard let node = try Yams.compose(yaml: yaml) else { return Node.Mapping([]) }
            return node.mapping
        } catch {
            return nil
        }
    }

    /// The paths a top-level key lists: the items of a list, or a lone string.
    static func paths(_ key: String, in settings: Node.Mapping) -> [String] {
        guard let node = settings[key] else { return [] }
        if let items = node.sequence { return items.compactMap(\.string) }
        return node.null == nil ? [node.string].compactMap { $0 } : []
    }

    /// `path` without what doesn't change which folder it names: `./` in front, and `/`, `/*`, or `/**` behind.
    static func folder(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespaces)
        while path.hasPrefix("./") { path.removeFirst(2) }
        if let ending = ["/**/*", "/**", "/*", "/"].first(where: path.hasSuffix) { path.removeLast(ending.count) }
        return path
    }

    /// Whether a path in the config names `.xcdev`, also as a pattern (`.*`).
    static func covers(_ path: String) -> Bool {
        let folder = folder(path)
        return folder == stateFolder || fnmatch(folder, stateFolder, 0) == 0
    }

    /// Whether a path in the config names the config's own folder.
    static func isRoot(_ path: String) -> Bool { ["", "."].contains(folder(path)) }

    /// Whether `edited` says what this config says, plus `.xcdev` at the end of `excluded`.
    func isThisPlusTheFolder(_ edited: String) -> Bool {
        guard let before = Self.settings(text), let after = Self.settings(edited) else { return false }
        func others(_ settings: Node.Mapping) -> [Node.Mapping.Element] { settings.filter { $0.key.string != Self.excludedKey } }
        return others(before).elementsEqual(others(after)) { $0.key == $1.key && $0.value == $1.value }
            && Self.paths(Self.excludedKey, in: after) == Self.paths(Self.excludedKey, in: before) + [Self.stateFolder]
    }

    /// The text with `.xcdev` added to the top-level `excluded`, as a new last item of a list written one item to a
    /// line or on one line, or as a new list at the end of the file. Nil for any other layout.
    func edited() -> String? {
        var lines = Self.lines(text)
        let lineBreak = String(text.first(where: \.isNewline) ?? "\n")
        guard let key = lines.firstIndex(where: { $0.hasPrefix(Self.excludedKey + ":") }) else {
            var result = text
            if let last = result.last, !last.isNewline { result += lineBreak }
            if !result.isEmpty, !result.hasSuffix(lineBreak + lineBreak) { result += lineBreak }
            return result + Self.excludedKey + ":" + lineBreak + "  - " + Self.stateFolder + lineBreak
        }
        let value = Self.withoutComment(lines[key].dropFirst(Self.excludedKey.count + 1))
        if value.isEmpty {
            let (last, indent) = Self.lastItem(of: lines, after: key)
            if lines[last].last?.isNewline != true { lines[last] += lineBreak }
            lines.insert(indent + "- " + Self.stateFolder + lineBreak, at: last + 1)
        } else if value.hasPrefix("["), let close = lines[key].firstIndex(of: "]") {
            let open = lines[key].firstIndex(of: "[") ?? close
            let items = lines[key][lines[key].index(after: open)..<close]
            let end = lines[key].index(open, offsetBy: 1 + items.count - items.reversed().prefix { $0 == " " }.count)
            lines[key].insert(contentsOf: (items.allSatisfy { $0 == " " } ? "" : ", ") + Self.stateFolder, at: end)
        } else {
            return nil
        }
        return lines.joined()
    }

    /// The last line of the list under the key on line `key`, and the indentation of its items. Lines indented deeper
    /// than the items continue one of them. With no item, the key's own line and two spaces.
    static func lastItem(of lines: [String], after key: Int) -> (line: Int, indent: String) {
        var last = key
        var indent: String?
        for index in lines.indices.dropFirst(key + 1) {
            let content = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty || content.hasPrefix("#") { continue }
            let leading = String(lines[index].prefix { $0 == " " })
            let isItem = content == "-" || content.hasPrefix("- ")
            if isItem, leading == indent ?? leading {
                indent = leading
            } else if let indent, leading.count > indent.count {
                // part of the item above
            } else {
                break
            }
            last = index
        }
        return (last, indent ?? "  ")
    }

    /// `text` in lines, each with its line break.
    static func lines(_ text: String) -> [String] {
        var lines: [String] = []
        var start = text.startIndex
        for index in text.indices where text[index].isNewline {
            let next = text.index(after: index)
            lines.append(String(text[start..<next]))
            start = next
        }
        if start < text.endIndex { lines.append(String(text[start...])) }
        return lines
    }

    /// What a line holds before its comment, without the spaces around it.
    static func withoutComment(_ line: some StringProtocol) -> String {
        let line = " " + line
        return (line.range(of: " #").map { String(line[..<$0.lowerBound]) } ?? String(line)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
