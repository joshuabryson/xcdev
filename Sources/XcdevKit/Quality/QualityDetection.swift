/// What a project has that a quality tool reads: used by the commands, `init`, and `doctor`.
public enum QualityDetection {
    /// The SwiftLint config in the worktree root: its name, or nil when the root has none.
    public static func lintConfigFile(in root: String) -> String? {
        SwiftLintConfig.load(in: root) == nil ? nil : SwiftLintConfig.fileName
    }
}
