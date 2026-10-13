import Foundation

/// What a project has that a quality tool reads: used by the commands, `init`, and `doctor`.
public enum QualityDetection {
    /// The SwiftLint config in the worktree root: its name, or nil when the root has none.
    public static func lintConfigFile(in root: String) -> String? {
        SwiftLintConfig.load(in: root) == nil ? nil : SwiftLintConfig.fileName
    }

    /// The formatters whose config file is in the worktree root: `.swift-format` for Apple's, `.swiftformat` for
    /// SwiftFormat. A link to a file counts. Both can be there, and then nothing says which one the project uses.
    public static func formatters(configuredIn root: String) -> [FormatterKind] {
        FormatterKind.allCases.filter { Disk.isRegularFile(URL(fileURLWithPath: root + "/" + $0.configFile).resolvingSymlinksInPath().path) }
    }
}
