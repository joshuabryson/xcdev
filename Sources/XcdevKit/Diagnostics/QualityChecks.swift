import Foundation

/// A project that has a SwiftLint config and whose .xcdev.yml never said whether `xcd lint` should use it
///. The fix adds the section. A project with no tool config is not a problem: there is
/// nothing to set up, and every project from before the section would otherwise fail doctor. `tool: none` is
/// left alone too: doctor cannot tell a config file added later from one the person declined.
public struct QualitySetupCheck: DoctorCheck {
    static let section = "lint:\n  tool: swiftlint\n"
    static let byHand = "add `lint: { tool: swiftlint }` to \(ConfigLoader.fileName)"

    public let id = "quality-setup"

    /// Only in a project whose config loads.
    public func applies(_ env: DoctorEnvironment) -> Bool { env.project?.config != nil }

    public func detect(_ env: DoctorEnvironment) -> [DoctorProblem] {
        guard let project = env.project, project.config?.lintSetup == .absent else { return [] }
        let root = project.location.worktreeRoot
        guard let found = QualityDetection.lintConfigFile(in: root) else { return [] }
        let message = "\(ConfigLoader.fileName) has no `lint:` section, and the project has a \(found), so `xcd lint` is not set up"
        return [DoctorProblem(check: id, message: message, action: .addLintSection, fix: Self.byHand + "; the change is then yours to commit",
                              subject: root + "/" + ConfigLoader.fileName)]
    }

    /// Adds the section at the end of the file as it is now, not as `detect` saw it, and writes the result only
    /// when it loads as a config that names SwiftLint.
    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) throws {
        guard problem.action == .addLintSection, let project = env.project else { return }
        let path = project.location.worktreeRoot + "/" + ConfigLoader.fileName
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let local = [project.location.worktreeRoot, project.location.projectRoot].lazy
            .compactMap { try? String(contentsOfFile: $0 + "/" + ConfigLoader.localFileName, encoding: .utf8) }.first
        guard (try? ConfigLoader.parse(main: text, local: local))?.lintSetup == .absent else {
            throw DoctorLeftAlone(note: "\(ConfigLoader.fileName) has a `lint:` section now; left alone")
        }
        let edited = text + (text.hasSuffix("\n") ? "" : "\n") + Self.section
        guard case .swiftlint? = (try? ConfigLoader.parse(main: edited, local: local))?.lintSetup else {
            throw XcdError(.internalError, "doctor can't add the section to this \(ConfigLoader.fileName)", next: Self.byHand + " by hand")
        }
        try edited.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// The linter the config names is not on this Mac, or `lint.path` names nothing. There is no
/// fix: xcd installs nothing.
public struct QualityToolsCheck: DoctorCheck {
    public let id = "quality-tools"
    let locator: ToolLocator

    public init(locator: ToolLocator = ToolLocator(environment: ProcessInfo.processInfo.environment)) {
        self.locator = locator
    }

    /// Only in a project whose config loads.
    public func applies(_ env: DoctorEnvironment) -> Bool { env.project?.config != nil }

    public func detect(_ env: DoctorEnvironment) -> [DoctorProblem] {
        guard let project = env.project, case .swiftlint(let path, _)? = project.config?.lintSetup else { return [] }
        guard locator.locate(LintService.swiftLint, path: path, worktreeRoot: project.location.worktreeRoot) == nil else { return [] }
        let missing = ToolLocator.missing(LintService.swiftLint, section: LintService.section, path: path)
        return [DoctorProblem(check: id, message: missing.message, next: missing.next)]
    }

    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) {
        // Nothing to repair: the problem says how to install the tool or where to point at it.
    }
}
