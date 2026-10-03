import Foundation

/// The values shell completion offers for options and arguments (see `xcd --generate-completion-script`).
/// It runs on every Tab, so it never fails: outside a project, or with a broken config, it offers nothing.
public struct Completions: Sendable {
    public let runner: any ProcessRunning
    public let globalPaths: GlobalPaths
    public let currentDirectory: String

    public init(runner: any ProcessRunning, globalPaths: GlobalPaths, currentDirectory: String) {
        self.runner = runner
        self.globalPaths = globalPaths
        self.currentDirectory = currentDirectory
    }

    public static func live() -> Completions {
        Completions(runner: SystemProcessRunner(), globalPaths: .live(),
                    currentDirectory: FileManager.default.currentDirectoryPath)
    }

    public static var guideTopics: [String] { Guides.all.map(\.topic) }
    public static var configKeys: [String] { ConfigExplainer.keys().map(\.key) }

    public func devices() async -> [String] {
        await config()?.allDevices.keys.sorted() ?? []
    }

    /// The keys under schemes: that are set, then the scheme names they hold.
    public func schemes() async -> [String] {
        guard let schemes = await config()?.schemes else { return [] }
        let set = [("app", schemes.app), ("test", schemes.test)].filter { $0.1 != nil }
        var seen = Set<String>()
        return (set.map(\.0) + set.compactMap(\.1)).filter { seen.insert($0).inserted }
    }

    public func presets() async -> [String] {
        await config()?.presets?.keys.sorted() ?? []
    }

    /// This project's worktrees, by name, from the registry.
    public func worktrees() async -> [String] {
        guard let location = await location(),
              let entries = try? Registry(paths: globalPaths).entries() else { return [] }
        return entries.filter { $0.projectRoot == location.projectRoot }.map(\.name).sorted()
    }

    private func location() async -> ProjectLocation? {
        try? await WorktreeLocator(runner: runner).locate(from: currentDirectory)
    }

    private func config() async -> XcdevConfig? {
        guard let location = await location() else { return nil }
        return try? ConfigLoader.load(worktreeRoot: location.worktreeRoot, projectRoot: location.projectRoot)
    }
}
