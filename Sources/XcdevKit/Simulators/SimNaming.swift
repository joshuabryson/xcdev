public enum SimNaming {
    public static let templatePrefix = "xcd-template · "
    public static let clonePrefix = "xcd · "

    public static func template(_ resolved: ResolvedDevice) -> String {
        "\(templatePrefix)\(resolved.deviceType.name) · \(resolved.runtime.name)"
    }

    public static func clone(project: String, worktree: String, device: String) -> String {
        "\(clonePrefix)\(project) · \(worktree) · \(device)"
    }
}
