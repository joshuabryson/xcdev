import Foundation

/// `xcd init`: detect the project, plan the config, and write it. Never prompts.
public struct InitService: Sendable {
    public let runner: any ProcessRunning
    public let globalPaths: GlobalPaths
    public let discovery: XcodeDiscovery
    /// Shows the slow steps (reading packages' manifests, resolving packages, reading build settings) on stderr.
    public let progress: Activity
    /// Removes the run's scratch folder if Ctrl-C ends xcd during detection.
    public let interrupts: Interrupts
    /// Searched for Swift packages Xcode already resolved, when the project files don't say enough.
    public let xcodeDerivedData: String
    let now: @Sendable () -> Date
    /// Finds the linter, to say in its decision whether it is installed. By default it finds nothing.
    public var locator = ToolLocator(environment: [:], extraFolders: [])

    public init(runner: any ProcessRunning, globalPaths: GlobalPaths, discovery: XcodeDiscovery? = nil,
                progress: Activity = .silent, interrupts: Interrupts = .shared,
                xcodeDerivedData: String = ProjectDetector.defaultXcodeDerivedData, now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.globalPaths = globalPaths
        self.discovery = discovery ?? XcodeDiscovery(runner: runner)
        self.progress = progress
        self.interrupts = interrupts
        self.xcodeDerivedData = xcodeDerivedData
        self.now = now
    }

    /// `xcd init --plan`: writes nothing in the project.
    public func plan(from directory: String) async throws -> InitPlanReport {
        InitScratch.removeStale(in: globalPaths.cacheDirectory, now: now())
        let location = try await WorktreeLocator(runner: runner).locate(from: directory)
        let root = location.worktreeRoot
        var plan = try await makePlan(location, container: nil).adding(await quality.lintDecision(in: root))
        let exists = configExists(root)
        if let note = swiftLintNote(in: root, configExists: exists) { plan = plan.noting(note) }
        return InitPlanReport(plan: plan, root: root, configExists: exists)
    }

    /// What `--plan` says about a .swiftlint.yml that has SwiftLint search .xcdev/; nil when there is nothing to
    /// say. A plain `init` changes nothing in a project that has a config, and no `init` edits a layout it doesn't
    /// know, so the note then names what does add the entry.
    func swiftLintNote(in root: String, configExists: Bool) -> String? {
        guard let lint = SwiftLintConfig.load(in: root), lint.searchesStateFolder else { return nil }
        guard !configExists, lint.excludingStateFolder != nil else { return lint.warning(fixedBy: SwiftLintConfig.doctorFix) }
        return SwiftLintConfig.problem + "; `xcd init` adds `\(SwiftLintConfig.stateFolder)` to its `excluded` list"
    }

    /// `xcd init`, `--defaults`, and `--set`: writes .xcdev.yml from the recommendations and `answers`, adds
    /// .xcdev/ and .xcdev.local.yml to .gitignore, and keeps SwiftLint out of .xcdev/ (`excludeFromSwiftLint`).
    /// An existing .xcdev.yml is kept unless `force`: nothing is changed then.
    public func write(answers: [String: String], force: Bool, from directory: String) async throws -> InitReport {
        InitScratch.removeStale(in: globalPaths.cacheDirectory, now: now())
        let location = try await WorktreeLocator(runner: runner).locate(from: directory)
        let root = location.worktreeRoot
        let path = root + "/" + ConfigLoader.fileName
        if configExists(root), !force {
            guard answers.isEmpty else {
                throw XcdError(.usage, "\(ConfigLoader.fileName) already exists, so these answers were not applied",
                               next: "re-run with --force to replace it: `xcd init --force --set …`")
            }
            return unchanged(path: path, root: root)
        }
        let plan = try await makePlan(location, container: answers["project"])
        let linter = try QualityInit.chosen(answers, from: await quality.lintDecision(in: root))
        let generated = try QualityInit.adding(linter, to: plan.config(answers: answers.filter { $0.key != QualityInit.lintKey }))
        try generated.yaml.write(toFile: path, atomically: true, encoding: .utf8)
        let added = try Gitignore.ensure([".xcdev/", ConfigLoader.localFileName, ".xcdev-media/"], in: root)
        var report = InitReport(status: .written, path: path, summary: generated.summary, gitignoreAdded: added)
        excludeFromSwiftLint(in: root, &report)
        return report
    }

    /// What `init` reports when it keeps the .xcdev.yml that is there. It changes nothing then, so a .swiftlint.yml
    /// that has SwiftLint search .xcdev/ is a warning.
    func unchanged(path: String, root: String) -> InitReport {
        let config = try? ConfigLoader.load(worktreeRoot: root, projectRoot: root)
        let lint = SwiftLintConfig.load(in: root).flatMap { $0.searchesStateFolder ? $0 : nil }
        let warnings = (lint.map { [$0.warning(fixedBy: SwiftLintConfig.doctorFix)] } ?? []) + QualityInit.missingSections(config, in: root)
        return InitReport(status: .unchanged, path: path, summary: (config?.project).map { ["project: \($0)"] } ?? [],
                          gitignoreAdded: [], warnings: warnings)
    }

    var quality: QualityInit { QualityInit(runner: runner, locator: locator) }

    /// Adds .xcdev to the `excluded` list of the project's .swiftlint.yml when SwiftLint would search the folder
    /// (see `SwiftLintConfig`). A file that can't be edited or written is a warning: the config `init` came to
    /// write is in place.
    func excludeFromSwiftLint(in root: String, _ report: inout InitReport) {
        guard let lint = SwiftLintConfig.load(in: root), lint.searchesStateFolder else { return }
        if (try? lint.excludeStateFolder()) == true {
            report.swiftlintExcluded = [SwiftLintConfig.stateFolder]
        } else {
            report.warnings = [lint.warning(fixedBy: nil)]
        }
    }

    func configExists(_ root: String) -> Bool {
        FileManager.default.fileExists(atPath: root + "/" + ConfigLoader.fileName)
    }

    /// Detects `container` (or the best one found) in the worktree and plans the config. Detection reads the project
    /// files first and runs xcodebuild only when they don't say enough (see `ProjectDetector`). xcodebuild and SwiftPM
    /// work in a scratch folder under the cache directory, package checkouts included, deleted afterwards (also on
    /// Ctrl-C, once the children are stopped).
    func makePlan(_ location: ProjectLocation, container: String?) async throws -> InitPlan {
        let root = location.worktreeRoot
        let containers = ProjectDetector.containers(in: root)
        guard let best = containers.first else {
            throw XcdError(.notInProject, "no .xcworkspace, .xcodeproj, or Package.swift in \(root) or its subfolders",
                           next: "run `xcd init` from the folder that holds the Xcode project or Package.swift")
        }
        if let container, !containers.contains(container) {
            throw XcdError(.configInvalid, "'\(container)' is not an option for project",
                           next: "use one of: " + containers.joined(separator: ", "))
        }
        let installs = await discovery.installs()
        let selected = try? await discovery.resolve(spec: nil)
        let scratch = InitScratch.make(in: globalPaths.cacheDirectory)
        let cleanup = interrupts.addCleanup { try? FileManager.default.removeItem(atPath: scratch) }
        defer {
            interrupts.removeCleanup(cleanup)
            try? FileManager.default.removeItem(atPath: scratch)
        }
        let detector = ProjectDetector(runner: runner, developerDir: selected?.developerDir, scratch: scratch,
                                       xcodeDerivedData: xcodeDerivedData, progress: progress)
        let detected = try await detector.detect(root: root, container: container ?? best, projectRoot: location.projectRoot)
        let catalog = try await SimctlClient(runner: runner, developerDir: selected?.developerDir).catalog()
        return InitPlanner.plan(detected: detected, containers: containers, folder: URL(fileURLWithPath: root).lastPathComponent,
                                catalog: catalog, xcodes: installs, selected: selected)
    }
}

extension InitPlan {
    /// The plan with one more note.
    func noting(_ note: String) -> InitPlan {
        InitPlan(detected: detected, xcodes: xcodes, selectedXcode: selectedXcode, primary: primary, choices: choices,
                 notes: notes + [note])
    }
}

public enum Gitignore {
    /// Appends each entry `.gitignore` in `root` doesn't already list (with or without leading and trailing
    /// slashes), creating the file if needed. Returns the entries it added.
    public static func ensure(_ entries: [String], in root: String,
                              comment: String = "per-worktree build state and per-machine overrides") throws -> [String] {
        let path = root + "/.gitignore"
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        func normalized(_ line: some StringProtocol) -> String {
            line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let existing = Set(text.split(separator: "\n").map(normalized))
        let missing = entries.filter { !existing.contains(normalized($0)) }
        guard !missing.isEmpty else { return [] }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += "# xcdev: \(comment)\n" + missing.map { $0 + "\n" }.joined()
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return missing
    }
}

/// `xcd init` (without --plan).
public struct InitReport: Reportable {
    public enum Status: String, Codable, Sendable { case written, unchanged }

    public let status: Status
    public let path: String
    public let summary: [String]
    public let gitignoreAdded: [String]
    /// What was added to the `excluded` list of the project's .swiftlint.yml: `.xcdev`, or nothing.
    public var swiftlintExcluded: [String] = []
    public var warnings: [String] = []

    public var text: String {
        guard status == .written else {
            return (["\(ConfigLoader.fileName) already exists, so nothing changed  path=\(path)"] + summary
                + warnings.map { "warning: " + $0 }
                + ["next: inspect it with `xcd config show`; regenerate it with `xcd init --force` (plus any --set answers from `xcd init --plan`)"])
                .joined(separator: "\n")
        }
        var lines = ["wrote \(path)"] + summary
        lines.append(gitignoreAdded.isEmpty ? ".gitignore: already ignores .xcdev/, .xcdev.local.yml, and .xcdev-media/"
                                            : ".gitignore: added " + gitignoreAdded.joined(separator: ", "))
        if !swiftlintExcluded.isEmpty {
            lines.append("\(SwiftLintConfig.fileName): added \(swiftlintExcluded.joined(separator: ", ")) to `excluded`, "
                + "so SwiftLint stays out of xcd's build folder")
        }
        lines += warnings.map { "warning: " + $0 }
        lines.append("change a choice: `xcd init --force --set <key>=<value>` (`xcd init --plan` lists the keys), or edit .xcdev.yml (`xcd config explain <key>`)")
        lines.append("next: run `xcd config show` to check the result, then `xcd doctor`")
        return lines.joined(separator: "\n")
    }
}

public enum InitAnswers {
    /// `--set key=value` values. A key given twice keeps the last value.
    public static func parse(_ pairs: [String]) throws -> [String: String] {
        var answers: [String: String] = [:]
        for pair in pairs {
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                throw XcdError(.usage, "--set \(pair) is not KEY=VALUE",
                               next: "pass answers like `--set devices.default=\"iPhone 17 Pro\" xcode=system`")
            }
            answers[String(pair[..<equals]).trimmingCharacters(in: .whitespaces)] = String(pair[pair.index(after: equals)...])
        }
        return answers
    }
}
