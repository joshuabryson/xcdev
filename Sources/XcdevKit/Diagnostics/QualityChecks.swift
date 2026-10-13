import Foundation

/// A project that has a linter's or a formatter's config file and whose .xcdev.yml never said whether `xcd lint`
/// or `xcd format` should use it. The fix adds the section. A project with no tool config is
/// not a problem: there is nothing to set up, and every project from before the sections would otherwise fail
/// doctor. `tool: none` is left alone too: doctor cannot tell a config file added later from one the person
/// declined.
public struct QualitySetupCheck: DoctorCheck {
    static let section = "lint:\n  tool: swiftlint\n"
    static let edit = "`lint: { tool: swiftlint }` to \(ConfigLoader.fileName)"
    static let byHand = "add " + edit
    static let done = "added " + edit + "; the change is yours to commit"

    public let id = "quality-setup"

    /// Only in a project whose config loads.
    public func applies(_ env: DoctorEnvironment) -> Bool { env.project?.config != nil }

    /// One problem per section that is absent while its tool's config file is there.
    public func detect(_ env: DoctorEnvironment) -> [DoctorProblem] {
        guard let project = env.project, let config = project.config else { return [] }
        let root = project.location.worktreeRoot
        var problems: [DoctorProblem] = []
        if config.lintSetup == .absent, let found = QualityDetection.lintConfigFile(in: root) {
            let message = "\(ConfigLoader.fileName) has no `lint:` section, and the project has a \(found), so `xcd lint` is not set up"
            problems.append(DoctorProblem(check: id, message: message, action: .addLintSection, fix: Self.byHand + "; the change is then yours to commit",
                                          subject: root + "/" + ConfigLoader.fileName, done: Self.done))
        }
        if config.formatSetup == .absent { problems += formatProblem(QualityDetection.formatters(configuredIn: root), in: root) }
        return problems
    }

    /// With one formatter's config file the fix adds the section that names it. With both, nothing says which
    /// formatter the project uses, so the problem has no fix and says what to add by hand.
    func formatProblem(_ found: [FormatterKind], in root: String) -> [DoctorProblem] {
        guard let only = found.first else { return [] }
        let subject = root + "/" + ConfigLoader.fileName
        let files = found.map(\.configFile).joined(separator: " and ")
        let message = "\(ConfigLoader.fileName) has no `format:` section, and the project has a \(files), so `xcd format` is not set up"
        guard found.count == 1 else {
            let lines = found.map { "`format: { tool: \($0.rawValue) }`" }.joined(separator: " or ")
            return [DoctorProblem(check: id, message: message, next: "add \(lines) to \(ConfigLoader.fileName), whichever the project uses", subject: subject)]
        }
        let edit = "`format: { tool: \(only.rawValue) }` to \(ConfigLoader.fileName)"
        return [DoctorProblem(check: id, message: message, action: .addFormatSection, fix: "add \(edit); the change is then yours to commit",
                              subject: subject, done: "added \(edit); the change is yours to commit")]
    }

    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) throws {
        guard let project = env.project else { return }
        if problem.action == .addLintSection {
            try add(Self.section, byHand: Self.byHand, in: project) { $0.lintSetup == .absent }
        } else if problem.action == .addFormatSection {
            // Which formatter is read again too: a second config file may have come since.
            let found = QualityDetection.formatters(configuredIn: project.location.worktreeRoot)
            guard let only = found.first, found.count == 1 else {
                throw DoctorLeftAlone(note: "the project no longer has exactly one formatter's config file; left alone")
            }
            let line = "`format: { tool: \(only.rawValue) }` to \(ConfigLoader.fileName)"
            try add("format:\n  tool: \(only.rawValue)\n", byHand: "add " + line, in: project) { $0.formatSetup == .absent }
        }
    }

    /// Adds `section` at the end of the file as it is now, not as `detect` saw it, and writes the result only when
    /// it loads as a config that has the section. `isAbsent` says whether a config still lacks it.
    func add(_ section: String, byHand: String, in project: DoctorProject, isAbsent: (XcdevConfig) -> Bool) throws {
        let name = section.prefix { $0 != ":" }
        let path = project.location.worktreeRoot + "/" + ConfigLoader.fileName
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let local = [project.location.worktreeRoot, project.location.projectRoot].lazy
            .compactMap { try? String(contentsOfFile: $0 + "/" + ConfigLoader.localFileName, encoding: .utf8) }.first
        guard let now = try? ConfigLoader.parse(main: text, local: local), isAbsent(now) else {
            throw DoctorLeftAlone(note: "\(ConfigLoader.fileName) has a `\(name):` section now; left alone")
        }
        let edited = text + (text.hasSuffix("\n") ? "" : "\n") + section
        guard let loaded = try? ConfigLoader.parse(main: edited, local: local), !isAbsent(loaded) else {
            throw XcdError(.internalError, "doctor can't add the section to this \(ConfigLoader.fileName)", next: byHand + " by hand")
        }
        try edited.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// The linter or the formatter the config names is not on this Mac, or its `path` names nothing. There is no fix: xcd
/// installs nothing.
public struct QualityToolsCheck: DoctorCheck {
    public let id = "quality-tools"
    let locator: ToolLocator

    public init(locator: ToolLocator = ToolLocator(environment: ProcessInfo.processInfo.environment)) {
        self.locator = locator
    }

    /// Only in a project whose config loads.
    public func applies(_ env: DoctorEnvironment) -> Bool { env.project?.config != nil }

    /// Apple's swift-format is looked for in the worktree's Xcode, as `xcd format` looks for it.
    public func detect(_ env: DoctorEnvironment) async -> [DoctorProblem] {
        guard let project = env.project, let config = project.config else { return [] }
        let root = project.location.worktreeRoot
        var missing: [XcdError] = []
        if case .swiftlint(let path, _) = config.lintSetup, locator.locate(LintService.swiftLint, path: path, worktreeRoot: root) == nil {
            missing.append(ToolLocator.missing(LintService.swiftLint, section: LintService.section, path: path))
        }
        if case .tool(let kind, let path, _) = config.formatSetup {
            if let error = await formatterProblem(kind, path: path, in: project, env) { missing.append(error) }
        }
        return missing.map { DoctorProblem(check: id, message: $0.message, next: $0.next) }
    }

    /// The formatter's `tool_missing` error, or nil when it is found. An Xcode the config names that is not installed
    /// is the `project` check's problem and not this one's: it says so, and swift-format has nowhere to be looked for.
    private func formatterProblem(_ kind: FormatterKind, path: String?, in project: DoctorProject, _ env: DoctorEnvironment) async -> XcdError? {
        let place = FormatterLocator(tools: locator, runner: env.runner, discovery: env.discovery)
        let developerDir: String?
        do {
            developerDir = try await place.developerDir(for: kind, path: path, pinned: project.state?.xcode?.developerDir,
                                                        spec: project.config?.xcode)
        } catch {
            return nil
        }
        let found = await place.locate(kind, path: path, worktreeRoot: project.location.worktreeRoot, developerDir: developerDir)
        return found == nil ? FormatterLocator.missing(kind, path: path) : nil
    }

    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) {
        // Nothing to repair: the problem says how to install the tool or where to point at it.
    }
}
