import Foundation

/// The cross-field checks on `lint:`. Each issue names the key it is about.
enum QualityValidation {
    /// SwiftLint arguments xcd sets itself, or that would change what its run means.
    static let swiftLintOwned = [
        "--reporter", "--output", "--quiet", "--progress", "--cache-path", "--no-cache", "--use-stdin", "--fix",
        "--autocorrect", "--format", "--baseline", "--write-baseline", "--working-directory",
        "--use-script-input-files", "--use-script-input-file-lists",
    ]

    static func issues(_ config: XcdevConfig) -> [ConfigIssue] {
        guard let lint = config.lint else { return [] }
        let runs = lint.tool != nil && lint.tool != .off
        return ToolSectionCheck(section: "lint", hasTool: lint.tool != nil, toolRuns: runs, path: lint.path,
                                args: lint.args, run: lint.run, owned: swiftLintOwned).issues()
    }
}

/// The checks every tool section shares: one of `tool` and `run`, and what may stand beside each.
struct ToolSectionCheck {
    let section: String
    let hasTool: Bool
    /// The section names a tool that runs: any tool but `none`.
    let toolRuns: Bool
    let path: String?
    let args: [String]?
    let run: String?
    /// The tool's arguments that xcd sets itself.
    let owned: [String]

    func issue(_ key: String, _ message: String) -> ConfigIssue {
        ConfigIssue(path: key.isEmpty ? section : section + "." + key, message: message)
    }

    func issues() -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        if hasTool && run != nil { issues.append(issue("", "has tool and run; a section has exactly one of them")) }
        if !hasTool && run == nil { issues.append(issue("", "needs one of tool or run")) }
        if let run, isBlank(run) { issues.append(issue("run", "must not be empty")) }
        if let path { issues += toolOnly("path") + (isBlank(path) ? [issue("path", "must not be empty")] : []) }
        if let args { issues += toolOnly("args") + ownedIssues(args) }
        return issues
    }

    func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    /// `path` and `args` mean nothing beside `run` or `tool: none`.
    func toolOnly(_ key: String) -> [ConfigIssue] {
        toolRuns && run == nil ? [] : [issue(key, "is only read with a tool other than none")]
    }

    /// The arguments in `args` that xcd sets itself, written alone or as `--name=value`.
    func ownedIssues(_ args: [String]) -> [ConfigIssue] {
        let names = args.map { String($0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }
        let found = names.filter(owned.contains)
        guard !found.isEmpty else { return [] }
        return [issue("args", "xcd sets these itself, so they can't be given: \(found.joined(separator: ", "))")]
    }
}
