import Foundation

/// The cross-field checks on `lint:` and `format:`. Each issue names the key it is about.
enum QualityValidation {
    /// SwiftLint arguments xcd sets itself, or that would change what its run means.
    static let swiftLintOwned = [
        "--reporter", "--output", "--quiet", "--progress", "--cache-path", "--no-cache", "--use-stdin", "--fix",
        "--autocorrect", "--format", "--baseline", "--write-baseline", "--working-directory",
        "--use-script-input-files", "--use-script-input-file-lists",
    ]

    /// What xcd sets itself for each formatter: the range, where the text comes from and goes, and how much is said.
    static let formatterOwned: [FormatterKind: [String]] = [
        .appleSwiftFormat: ["--lines", "--offsets", "-i", "--in-place", "-r", "--recursive", "-p", "--parallel", "--assume-filename"],
        .swiftFormat: [
            "--line-range", "--stdin-path", "--output", "--filelist", "--lint", "--dry-run", "--report", "--reporter", "--cache",
            "--quiet", "--verbose", "--script-input", "--linerange", "--stdinpath", "--dryrun", "--scriptinput",
        ],
    ]

    /// Arguments with which a formatter exits 0 and prints something that is not the file (its version, its help, a
    /// list of its rules), which xcd would write over the file, and SwiftFormat's `--strict`, with which it fails on
    /// every file it reformats. `--rules` with nothing after it lists the rules, so the rules are named in .swiftformat.
    static let formatterMisused: [FormatterKind: [String]] = [
        .appleSwiftFormat: ["--version", "--help", "-h"],
        .swiftFormat: ["--version", "--help", "--options", "--rules", "--ruleinfo", "--rule-info", "--inferoptions", "--infer-options", "--strict"],
    ]

    static func issues(_ config: XcdevConfig) -> [ConfigIssue] {
        lintIssues(config.lint) + formatIssues(config.format)
    }

    static func lintIssues(_ lint: LintConfig?) -> [ConfigIssue] {
        guard let lint else { return [] }
        let runs = lint.tool != nil && lint.tool != .off
        return ToolSectionCheck(section: "lint", hasTool: lint.tool != nil, toolRuns: runs, path: lint.path,
                                args: lint.args, run: lint.run, owned: swiftLintOwned).issues()
    }

    /// `format:` has one more key than `lint:`: `check`, which is read only beside `run`.
    static func formatIssues(_ format: FormatConfig?) -> [ConfigIssue] {
        guard let format else { return [] }
        let kind = format.tool?.kind
        var section = ToolSectionCheck(section: "format", hasTool: format.tool != nil, toolRuns: kind != nil, path: format.path,
                                       args: format.args, run: format.run, owned: kind.flatMap { formatterOwned[$0] } ?? [])
        section.misused = kind.flatMap { formatterMisused[$0] } ?? []
        var issues = section.issues()
        if let check = format.check {
            if format.run == nil { issues.append(section.issue("check", "is only read with run")) }
            if section.isBlank(check) { issues.append(section.issue("check", "must not be empty")) }
        }
        return issues
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
    /// The tool's arguments that make its run something xcd cannot use.
    var misused: [String] = []

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

    /// The arguments in `args` that xcd sets itself, and the ones that would change what the run gives xcd, each
    /// written alone or as `--name=value`.
    func ownedIssues(_ args: [String]) -> [ConfigIssue] {
        let names = args.map { String($0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }
        let refusals = [(owned, "xcd sets these itself, so they can't be given"),
                        (misused, "these make the tool give xcd something other than the formatted file, so they can't be given")]
        return refusals.compactMap { list, why in
            let found = names.filter(list.contains)
            return found.isEmpty ? nil : issue("args", "\(why): \(found.joined(separator: ", "))")
        }
    }
}
