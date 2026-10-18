import Foundation

/// xcd's block in the AGENTS.md and CLAUDE.md of the checkout doctor runs in, kept as this xcd writes it. A file
/// without the block is not a problem: the project may have chosen none.
public struct AgentDocsCheck: DoctorCheck {
    public let id = "agent-docs"
    static let files = [AgentsInit.agentsFile] + AgentsInit.claudeFiles

    public init() { /* stateless */ }

    /// Only where doctor knows which project it is in.
    public func applies(_ env: DoctorEnvironment) -> Bool { env.location != nil && env.projectFailure == nil }

    /// Each real file once, by its real name, as `xcd init` names them; a link out of the checkout is not doctor's.
    public func detect(_ env: DoctorEnvironment) -> [DoctorProblem] {
        guard let root = env.location?.worktreeRoot else { return [] }
        var seen = Set<String>()
        return Self.files.compactMap { file -> DoctorProblem? in
            guard let source = AgentFile.read(root + "/" + file), let name = source.name(in: root),
                  seen.insert(name).inserted else { return nil }
            return problem(name, source)
        }
    }

    func problem(_ name: String, _ source: AgentFile) -> DoctorProblem? {
        switch AgentBlock.find(in: source.text) {
        case .none:
            return nil
        case .unclosed:
            return DoctorProblem(check: id, message: "\(name) has an xcd begin marker with no end marker after it",
                                 next: "fix the xcd markers in \(name) by hand", subject: source.path)
        case .block:
            guard !AgentBlock.isCurrent(in: source.text) else { return nil }
            return DoctorProblem(check: id, message: "\(name)'s xcd block differs from this xcd's", action: .rewriteAgentBlock,
                                 fix: "rewrite it", subject: source.path, done: "rewrote it; the change is yours to commit")
        }
    }

    /// Rewrites only the text between the markers, as the file is now: changes elsewhere in it, committed or not, stay.
    /// A byte order mark and a link stay, as `xcd init` keeps them. A file that changed since `detect` (the block is
    /// this xcd's, gone, or has lost its end marker, or the file leads outside the checkout) is left alone.
    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) throws {
        guard let path = problem.subject, let root = env.location?.worktreeRoot else { return }
        guard let source = AgentFile.read(path) else { throw DoctorLeftAlone(note: "the file cannot be read as UTF-8 now; left alone") }
        let file = URL(fileURLWithPath: path).lastPathComponent
        guard let name = source.name(in: root) else { throw DoctorLeftAlone(note: "\(file) leads outside this checkout now; left alone") }
        guard case .block = AgentBlock.find(in: source.text) else {
            let gone = AgentBlock.find(in: source.text) == .none
            throw DoctorLeftAlone(note: "\(name)'s xcd " + (gone ? "block is gone" : "end marker is gone") + " now; left alone")
        }
        guard !AgentBlock.isCurrent(in: source.text), let written = AgentBlock.written(into: source.text) else {
            throw DoctorLeftAlone(note: "\(name)'s xcd block is this xcd's now; left alone")
        }
        try source.write(written)
    }
}
