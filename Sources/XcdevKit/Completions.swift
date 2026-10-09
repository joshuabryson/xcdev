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

    /// The options of `xcd open` that take a value, which is a word of its own unless it is written `--name=value`.
    static let openOptionsWithValues: Set<String> = ["--preset", "--device", "--xcode", "--worktree"]

    /// The project's route names, for the first argument of `xcd open`. `words` is the command
    /// line and `index` the word being completed. What follows a route name is its parameters: nothing is offered.
    public func routes(_ words: [String], at index: Int) async -> [String] {
        guard let command = words.firstIndex(of: "open") else { return [] }
        var takesValue = false
        for word in words[..<min(index, words.count)].dropFirst(command + 1) {
            if takesValue {
                takesValue = false
            } else if word.hasPrefix("-") {
                takesValue = Self.openOptionsWithValues.contains(word)
            } else {
                return []               // an argument is already there: the route, or a link
            }
        }
        if takesValue { return [] }     // the word being completed is an option's value
        return await config()?.routes.keys.sorted() ?? []
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
