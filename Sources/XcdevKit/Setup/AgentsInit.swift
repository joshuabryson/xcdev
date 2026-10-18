import Foundation

/// Which of a checkout's AGENTS.md and CLAUDE.md get xcd's block, and writing it there.
struct AgentsInit: Sendable {
    static let key = "agents"
    static let options = ["both", "AGENTS.md", "CLAUDE.md", "none"]
    static let agentsFile = "AGENTS.md"
    /// Claude Code reads either as the project's instructions.
    static let claudeFiles = ["CLAUDE.md", ".claude/CLAUDE.md"]

    let root: String

    var agents: String? { Self.present(root + "/" + Self.agentsFile) ? Self.agentsFile : nil }
    var claude: String? { Self.claudeFiles.first { Self.present(root + "/" + $0) } }

    /// Whether a file or a link is at `path`; a link counts whether or not it leads anywhere.
    static func present(_ path: String) -> Bool {
        Disk.exists(path) || (try? FileManager().destinationOfSymbolicLink(atPath: path)) != nil
    }

    /// The decision `xcd init --plan` lists when the checkout has neither file; nil when it has one of them.
    var decision: InitDecision? {
        guard agents == nil, claude == nil else { return nil }
        return InitDecision(key: Self.key,
                            ask: "Which files should tell agents to use xcd? Codex, Cursor, and most other agent tools read AGENTS.md. "
                                + "Claude Code reads CLAUDE.md, and reads AGENTS.md only when there is no CLAUDE.md or CLAUDE.local.md "
                                + "in the folder or above it.",
                            options: Self.options, recommended: "both",
                            reason: "`both` puts the block in AGENTS.md and a CLAUDE.md that imports it, so every tool reads it once")
    }

    /// The option `answer` names, in any case, or the recommendation when there is none.
    static func chosen(_ answer: String?) throws -> String {
        let value = (answer ?? "both").trimmingCharacters(in: .whitespaces)
        guard let option = options.first(where: { $0.lowercased() == value.lowercased() }) else {
            throw XcdError(.configInvalid, "'\(value)' is not an option for \(key)", next: "use one of: " + options.joined(separator: ", "))
        }
        return option
    }

    /// The option `answer` names, refused when it does not apply: only `none` applies to a project that has one of the files.
    @discardableResult
    func check(answer: String?) throws -> String {
        let choice = try Self.chosen(answer)
        if answer != nil, choice != "none", let have = agents ?? claude {
            throw XcdError(.usage, "agents=\(choice) applies only to a project with neither AGENTS.md nor CLAUDE.md, and this one has \(have)",
                           next: "leave out agents to put xcd's block in the files it has, or use agents=none for none")
        }
        return choice
    }

    /// Writes the block into the files of the two the checkout has (the Claude file only when it does not import
    /// AGENTS.md), or, when it has neither, into those `answer` names. `none` writes nothing.
    func install(answer: String?) throws -> AgentsInstall {
        var result = AgentsInstall()
        let choice = try check(answer: answer)
        guard choice != "none" else { return result }
        guard agents == nil, claude == nil else {
            writeExisting(into: &result)
            return result
        }
        if choice != "CLAUDE.md" { create(Self.agentsFile, AgentBlock.text + "\n", "created with xcd's block", into: &result) }
        if choice == "both" { create("CLAUDE.md", "@AGENTS.md\n", "created, importing AGENTS.md", into: &result) }
        if choice == "CLAUDE.md" { create("CLAUDE.md", AgentBlock.text + "\n", "created with xcd's block", into: &result) }
        return result
    }

    /// The block into each file the checkout has, once for each file the bytes are in (a link and its target are one).
    func writeExisting(into result: inout AgentsInstall) {
        var seen = Set<String>()
        let files = [agents, claude.flatMap { agents == nil || !imports($0) ? $0 : nil }].compactMap { $0 }
        for file in files where seen.insert(AgentFile.read(root + "/" + file)?.name(in: root) ?? file).inserted {
            write(file, into: &result)
        }
    }

    func imports(_ file: String) -> Bool {
        AgentBlock.importsAgentsFile(AgentFile.read(root + "/" + file)?.text ?? "", from: file)
    }

    func create(_ file: String, _ text: String, _ line: String, into result: inout AgentsInstall) {
        guard (try? text.write(toFile: root + "/" + file, atomically: true, encoding: .utf8)) != nil else {
            return result.warnings.append("xcd could not create \(file), so it left it out")
        }
        result.lines.append("\(file): \(line)")
        result.changed.append(file)
    }

    /// Puts this xcd's block in `file`. A file it cannot read or write, a link out of the checkout, or a file whose begin
    /// marker has no end, is left alone with a warning; one that mentions xcd outside the block gets a warning too.
    func write(_ file: String, into result: inout AgentsInstall) {
        guard let source = AgentFile.read(root + "/" + file) else {
            return result.warnings.append("xcd could not read \(file) as UTF-8 text, so it left it alone")
        }
        guard let name = source.name(in: root) else {
            return result.warnings.append("\(file) is a link to \(source.path), outside this checkout, so xcd left it alone: "
                + "ask the user whether xcd's block belongs there")
        }
        guard let written = AgentBlock.written(into: source.text) else {
            return result.warnings.append("\(name) has an xcd begin marker with no end marker after it, so xcd left it alone: fix the markers by hand")
        }
        if AgentBlock.mentionsXcdOutside(source.text) {
            result.warnings.append("\(name) also mentions xcd outside xcd's block: show the user those lines, and ask which to keep; "
                + "the block now says what xcd needs agents to know")
        }
        guard written != source.text else { return result.lines.append("\(name): xcd's block is current") }
        guard (try? source.write(written)) != nil else {
            return result.warnings.append("xcd could not write \(name), so it left it as it was")
        }
        result.lines.append("\(name): " + (AgentBlock.find(in: source.text) == .none ? "added xcd's block" : "updated xcd's block"))
        result.changed.append(name)
    }
}

/// What installing the block did.
public struct AgentsInstall: Codable, Sendable, Equatable {
    /// One line per file: what was done to it.
    public var lines: [String] = []
    /// The files changed or created, which are the user's to commit.
    public var changed: [String] = []
    public var warnings: [String] = []
}

/// `xcd init --agents`.
public struct AgentsReport: Reportable {
    public let agents: AgentsInstall

    public var text: String {
        let lines = (agents.lines.isEmpty ? ["no file was given xcd's block"] : agents.lines) + agents.warnings.map { "warning: " + $0 }
        return (lines + (agents.changed.isEmpty ? [] : ["commit " + Self.listed(agents.changed)])).joined(separator: "\n")
    }

    /// "A", "A and B", or "A, B, and C".
    static func listed(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.count == 2 ? "\(items[0]) and \(last)" : items.dropLast().joined(separator: ", ") + ", and " + last
    }
}

/// A file that holds xcd's block, read and written so that nothing outside the markers changes: a UTF-8 byte order
/// mark is kept, and a symbolic link is written through, not replaced.
struct AgentFile {
    private static let mark = Data([0xEF, 0xBB, 0xBF])

    /// The path with links resolved.
    let path: String
    /// The text without the byte order mark.
    let text: String
    let byteOrderMark: Bool

    /// Nil when the file can't be read as UTF-8.
    static func read(_ path: String) -> AgentFile? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)) else { return nil }
        let marked = data.starts(with: mark)
        guard let text = String(data: marked ? data.dropFirst(mark.count) : data, encoding: .utf8) else { return nil }
        return AgentFile(path: resolved, text: text, byteOrderMark: marked)
    }

    /// The file's name in the checkout at `root`, or nil when it is outside it.
    func name(in root: String) -> String? {
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }

    /// Writes `text` atomically to `path`, the byte order mark first when the file had one. A file that may not be
    /// written (the atomic rename would replace it all the same) throws.
    func write(_ text: String) throws {
        guard access(path, W_OK) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        try (byteOrderMark ? Self.mark + Data(text.utf8) : Data(text.utf8)).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
