import Foundation

/// The `lint.tool` decision of `xcd init`, and the `lint:` section init writes.
struct QualityInit: Sendable {
    static let lintKey = "lint.tool"

    let runner: any ProcessRunning
    let locator: ToolLocator

    /// Whether `xcd lint` should run SwiftLint. It is recommended when the project has a .swiftlint.yml, and
    /// `none` is otherwise, so that `xcd init --defaults` never turns on a tool nobody picked. The question says
    /// whether SwiftLint is on this Mac.
    func lintDecision(in root: String) async -> InitDecision {
        let found = QualityDetection.lintConfigFile(in: root) != nil
        let tools = LintConfig.Tool.allCases.map(\.rawValue)
        let question = found
            ? "This project has a \(SwiftLintConfig.fileName). Should `xcd lint` run SwiftLint?"
            : "No linter is set up in this project. Should `xcd lint` run SwiftLint? It would use SwiftLint's default rules "
                + "until the project adds a \(SwiftLintConfig.fileName)."
        return InitDecision(key: Self.lintKey, ask: question + " " + (await installed(root)),
                            options: found ? tools : tools.reversed(), recommended: (found ? LintConfig.Tool.swiftlint : .off).rawValue,
                            reason: "the project has \(found ? "a" : "no") \(SwiftLintConfig.fileName)")
    }

    /// Whether SwiftLint is on this Mac, with its version when it gives one, or how to install it.
    func installed(_ root: String) async -> String {
        guard let executable = locator.locate(LintService.swiftLint, path: nil, worktreeRoot: root) else {
            return "SwiftLint is not installed on this Mac; `brew install swiftlint` installs it."
        }
        let answer = try? await runner.run(Invocation(executable, ["version"]))
        let version = answer.flatMap { $0.succeeded ? $0.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) : nil } ?? ""
        return "SwiftLint \(version.isEmpty ? "" : version + " ")is installed on this Mac."
    }

    /// The linter to write: the answer for `lint.tool` when there is one, else the decision's recommendation. An
    /// answer that is not an option is `config_invalid`, as it is for every other key.
    static func chosen(_ answers: [String: String], from decision: InitDecision) throws -> LintConfig.Tool {
        let value = (answers[lintKey] ?? decision.recommended).trimmingCharacters(in: .whitespaces).lowercased()
        guard let tool = LintConfig.Tool(rawValue: value) else {
            throw XcdError(.configInvalid, "'\(answers[lintKey] ?? value)' is not an option for \(lintKey)",
                           next: "use one of: " + decision.options.sorted().joined(separator: ", "))
        }
        return tool
    }

    /// `generated` with the `lint:` section at its end. Init always writes it, `tool: none` included, so a config
    /// it writes is never in the "section absent" state.
    static func adding(_ tool: LintConfig.Tool, to generated: GeneratedConfig) throws -> GeneratedConfig {
        let yaml = generated.yaml + "lint:\n  tool: \(tool.rawValue)\n"
        do {
            _ = try ConfigLoader.parse(main: yaml)
        } catch {
            throw XcdError(.internalError, "xcd init generated an invalid .xcdev.yml", next: "this is a bug in xcd; please report it",
                           details: ["\(error)"] + yaml.split(separator: "\n").map(String.init))
        }
        return GeneratedConfig(yaml: yaml, summary: generated.summary + ["lint: \(tool.rawValue)"])
    }

    /// What `init` warns about when it keeps a config that has no `lint:` section: the lines to add.
    static func missingSections(_ config: XcdevConfig?, in root: String) -> [String] {
        guard let config, config.lintSetup == .absent else { return [] }
        let next = LintService.notConfigured(hasConfigFile: QualityDetection.lintConfigFile(in: root) != nil).next ?? ""
        return ["`xcd lint` is not set up: " + next]
    }
}

extension InitPlan {
    /// The plan with one more choice, asked last.
    func adding(_ choice: InitDecision) -> InitPlan {
        InitPlan(detected: detected, xcodes: xcodes, selectedXcode: selectedXcode, primary: primary, choices: choices + [choice],
                 notes: notes)
    }
}
