import Foundation

/// Finds the formatter a project names.
public struct FormatterLocator: Sendable {
    /// The config section that names a formatter.
    static let section = "format"

    public let tools: ToolLocator
    public let runner: any ProcessRunning
    /// How an Xcode the config names is found.
    let discovery: XcodeDiscovery

    public init(tools: ToolLocator, runner: any ProcessRunning, discovery: XcodeDiscovery? = nil) {
        self.tools = tools
        self.runner = runner
        self.discovery = discovery ?? XcodeDiscovery(runner: runner)
    }

    /// The Xcode whose swift-format `xcrun` is asked for, shared by `xcd format` and `xcd doctor` so they look in the
    /// same one: the worktree's (`pinned`), else the one the config names (`spec`), found as a build finds it but not
    /// pinned. Nil when `xcrun` should answer for the selected Xcode, and when no Xcode is involved: SwiftFormat, or
    /// a `format.path`. Throws when the pinned Xcode is no longer there, and when `spec` names an Xcode that is not
    /// installed.
    public func developerDir(for kind: FormatterKind, path: String?, pinned: XcodeInstall?, spec: String?) async throws -> String? {
        guard kind == .appleSwiftFormat, path == nil else { return nil }
        if let pinned {
            guard Disk.exists(pinned.path) else { throw Self.gone(pinned) }
            return pinned.developerDir
        }
        guard let spec else { return nil }
        return try await discovery.resolve(spec: spec).developerDir
    }

    /// The error for a worktree whose pinned Xcode is no longer there. `xcd doctor --fix` unpins it. Without this,
    /// `xcrun` finds no swift-format in an Xcode that is gone, and the error for that points at `format.tool` in the
    /// config the project shares, which is not what is wrong.
    static func gone(_ pinned: XcodeInstall) -> XcdError {
        XcdError(.xcodeMissing, "the worktree's Xcode is gone: it is pinned to \(pinned.path), which no longer exists",
                 next: "run `xcd doctor --fix`, which unpins it")
    }

    /// The formatter's executable, or nil when there is none. `path` is `format.path`, and with it the answer is
    /// that file or nothing. Without it, SwiftFormat is looked for as the linter is, and Apple's swift-format is the
    /// one inside an Xcode: `developerDir` names the worktree's, and nil means the one `xcode-select` names. xcd then
    /// runs it by its full path, which is quicker than through `xcrun` each time.
    public func locate(_ kind: FormatterKind, path: String?, worktreeRoot: String, developerDir: String?) async -> String? {
        if path != nil || kind == .swiftFormat { return tools.locate(kind.rawValue, path: path, worktreeRoot: worktreeRoot) }
        // What xcrun printed is taken only when it names a file that can be run, so its exit code needs no reading.
        guard let found = try? await runner.run(.xcrun(["--find", kind.rawValue], developerDir: developerDir)) else { return nil }
        let executable = found.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return Disk.isExecutable(executable) ? executable : nil
    }

    /// The `tool_missing` error for a formatter `locate` did not find. Nothing installs Apple's swift-format, so
    /// for it the next step names the other choices.
    public static func missing(_ kind: FormatterKind, path: String?) -> XcdError {
        var error = ToolLocator.missing(kind.rawValue, section: section, path: path)
        guard kind == .appleSwiftFormat else { return error }
        if path == nil {
            error.message = "the selected Xcode has no swift-format"
            error.next = "set format.tool to swiftformat or none in .xcdev.yml, or set format.path in .xcdev.local.yml to a swift-format outside Xcode"
        } else {
            error.next = "fix format.path in .xcdev.yml or .xcdev.local.yml, or remove it to have xcd use the swift-format inside Xcode"
        }
        return error
    }
}
