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
        let plan = try await makePlan(location, container: nil)
        return InitPlanReport(plan: plan, root: root, configExists: configExists(root))
    }

    /// `xcd init`, `--defaults`, and `--set`: writes .xcdev.yml from the recommendations and `answers`, and adds
    /// .xcdev/ and .xcdev.local.yml to .gitignore. An existing .xcdev.yml is kept unless `force`.
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
            let project = (try? ConfigLoader.load(worktreeRoot: root, projectRoot: root))?.project
            return InitReport(status: .unchanged, path: path, summary: project.map { ["project: \($0)"] } ?? [],
                              gitignoreAdded: [])
        }
        let plan = try await makePlan(location, container: answers["project"])
        let generated = try plan.config(answers: answers)
        try generated.yaml.write(toFile: path, atomically: true, encoding: .utf8)
        let added = try Gitignore.ensure([".xcdev/", ConfigLoader.localFileName], in: root)
        return InitReport(status: .written, path: path, summary: generated.summary, gitignoreAdded: added)
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

public enum Gitignore {
    /// Appends each entry `.gitignore` in `root` doesn't already list (with or without leading and trailing
    /// slashes), creating the file if needed. Returns the entries it added.
    public static func ensure(_ entries: [String], in root: String) throws -> [String] {
        let path = root + "/.gitignore"
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        func normalized(_ line: some StringProtocol) -> String {
            line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let existing = Set(text.split(separator: "\n").map(normalized))
        let missing = entries.filter { !existing.contains(normalized($0)) }
        guard !missing.isEmpty else { return [] }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += "# xcdev: per-worktree build state and per-machine overrides\n" + missing.map { $0 + "\n" }.joined()
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

    public var text: String {
        guard status == .written else {
            return (["\(ConfigLoader.fileName) already exists, so nothing changed  path=\(path)"] + summary
                + ["next: inspect it with `xcd config show`; regenerate it with `xcd init --force` (plus any --set answers from `xcd init --plan`)"])
                .joined(separator: "\n")
        }
        var lines = ["wrote \(path)"] + summary
        lines.append(gitignoreAdded.isEmpty ? ".gitignore: already ignores .xcdev/ and .xcdev.local.yml"
                                            : ".gitignore: added " + gitignoreAdded.joined(separator: ", "))
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
