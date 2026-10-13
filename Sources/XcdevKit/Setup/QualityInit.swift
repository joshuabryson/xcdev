import Foundation

/// The `lint.tool` and `format.tool` decisions of `xcd init`, and the two sections init writes.
struct QualityInit: Sendable {
    static let lintKey = "lint.tool"
    static let formatKey = "format.tool"
    /// The answers `init` reads here, before the planner sees the rest.
    static let keys = [lintKey, formatKey]

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
        return InitDecision(key: Self.lintKey, ask: question + " " + (await installed("SwiftLint", LintService.swiftLint, asking: "version", in: root)),
                            options: found ? tools : tools.reversed(), recommended: (found ? LintConfig.Tool.swiftlint : .off).rawValue,
                            reason: "the project has \(found ? "a" : "no") \(SwiftLintConfig.fileName)")
    }

    /// Which formatter `xcd format` should run. One is recommended only when the project has that formatter's
    /// config file and not the other's: with both files xcd cannot tell which the project uses, and with neither
    /// nobody picked one. The question says what a person needs to choose: whether each formatter is on this Mac.
    /// `developerDir` is the Xcode whose swift-format would run.
    func formatDecision(in root: String, developerDir: String?) async -> InitDecision {
        let found = QualityDetection.formatters(configuredIn: root)
        let apple = await aboutAppleSwiftFormat(in: root, developerDir: developerDir, hasConfig: found.contains(.appleSwiftFormat))
        let nick = await installed("SwiftFormat", FormatterKind.swiftFormat.rawValue, asking: "--version", in: root)
            + (found.contains(.swiftFormat) ? "" : " It would use its default rules until the project adds a .swiftformat file.")
        let none = FormatReport.noTool
        guard let only = found.first, found.count == 1 else {
            let both = !found.isEmpty
            let order = both ? [FormatterKind.swiftFormat, .appleSwiftFormat] : [.appleSwiftFormat, .swiftFormat]
            let question = both ? "This project has a .swiftformat and a .swift-format. Which formatter should `xcd format` run?"
                                : "No formatter is set up in this project. Do you want one?"
            return InitDecision(key: Self.formatKey, ask: [question, both ? nick : apple, both ? apple : nick].joined(separator: " "),
                                options: [none] + order.map(\.rawValue), recommended: none,
                                reason: both ? "the project has both files, so xcd can't tell which formatter it uses" : "the project has no formatter config")
        }
        let other = only == .swiftFormat ? FormatterKind.appleSwiftFormat : .swiftFormat
        let name = only == .swiftFormat ? "SwiftFormat" : "Xcode's swift-format"
        return InitDecision(key: Self.formatKey, ask: "This project has a \(only.configFile). Should `xcd format` run \(name)? " + (only == .swiftFormat ? nick : apple),
                            options: [only.rawValue, none, other.rawValue], recommended: only.rawValue, reason: "the project has a \(only.configFile)")
    }

    /// What a person needs to know about Apple's swift-format: that it comes with Xcode, and what it does with no
    /// config file of its own.
    func aboutAppleSwiftFormat(in root: String, developerDir: String?, hasConfig: Bool) async -> String {
        let place = FormatterLocator(tools: locator, runner: runner)
        guard await place.locate(.appleSwiftFormat, path: nil, worktreeRoot: root, developerDir: developerDir) != nil else {
            return "The selected Xcode has no swift-format."
        }
        return "Xcode's swift-format needs no install" + (hasConfig ? "." : " and indents with 2 spaces unless you add a .swift-format file.")
    }

    /// Whether the tool named `title`, whose command is `command`, is on this Mac, with its version when it gives
    /// one for `asking`, or how to install it.
    func installed(_ title: String, _ command: String, asking: String, in root: String) async -> String {
        guard let executable = locator.locate(command, path: nil, worktreeRoot: root) else {
            return "\(title) is not installed on this Mac; `brew install \(command)` installs it."
        }
        let answer = try? await runner.run(Invocation(executable, [asking]))
        let version = answer.flatMap { $0.succeeded ? $0.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) : nil } ?? ""
        return "\(title) \(version.isEmpty ? "" : version + " ")is installed on this Mac."
    }

    /// The option to write for `decision`: the answer for its key when there is one, else its recommendation. An
    /// answer that is not an option is `config_invalid`, as it is for every other key.
    static func chosen(_ answers: [String: String], from decision: InitDecision) throws -> String {
        let value = (answers[decision.key] ?? decision.recommended).trimmingCharacters(in: .whitespaces).lowercased()
        guard decision.options.contains(value) else {
            throw XcdError(.configInvalid, "'\(answers[decision.key] ?? value)' is not an option for \(decision.key)",
                           next: "use one of: " + decision.options.sorted().joined(separator: ", "))
        }
        return value
    }

    /// `generated` with the `lint:` and `format:` sections at its end. Init always writes both, `tool: none`
    /// included, so a config it writes is never in the "section absent" state.
    static func adding(lint: String, format: String, to generated: GeneratedConfig) throws -> GeneratedConfig {
        let yaml = generated.yaml + "lint:\n  tool: \(lint)\nformat:\n  tool: \(format)\n"
        do {
            _ = try ConfigLoader.parse(main: yaml)
        } catch {
            throw XcdError(.internalError, "xcd init generated an invalid .xcdev.yml", next: "this is a bug in xcd; please report it",
                           details: ["\(error)"] + yaml.split(separator: "\n").map(String.init))
        }
        return GeneratedConfig(yaml: yaml, summary: generated.summary + ["lint: \(lint)", "format: \(format)"])
    }

    /// What `init` warns about when it keeps a config that has no `lint:` or no `format:` section: the lines to add.
    static func missingSections(_ config: XcdevConfig?, in root: String) -> [String] {
        guard let config else { return [] }
        var warnings: [String] = []
        if config.lintSetup == .absent {
            warnings.append("`xcd lint` is not set up: " + (LintService.notConfigured(hasConfigFile: QualityDetection.lintConfigFile(in: root) != nil).next ?? ""))
        }
        if config.formatSetup == .absent {
            warnings.append("`xcd format` is not set up: " + (FormatService.notConfigured(QualityDetection.formatters(configuredIn: root)).next ?? ""))
        }
        return warnings
    }
}

extension InitPlan {
    /// The plan with one more choice, asked last.
    func adding(_ choice: InitDecision) -> InitPlan {
        InitPlan(detected: detected, xcodes: xcodes, selectedXcode: selectedXcode, primary: primary, choices: choices + [choice],
                 notes: notes)
    }
}
