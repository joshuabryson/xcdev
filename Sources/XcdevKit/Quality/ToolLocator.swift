import Foundation

/// Finds a linter's executable.
public struct ToolLocator: Sendable {
    /// Where Homebrew puts commands, on Apple silicon and on Intel. An agent's shell often has a shorter PATH
    /// than the person's own.
    public static let usualFolders = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The folders looked in, in order: PATH's, then the usual ones.
    public let folders: [String]

    public init(environment: [String: String], extraFolders: [String] = ToolLocator.usualFolders) {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        folders = path + extraFolders.filter { !path.contains($0) }
    }

    /// The executable for the tool `name`. With `path` from the config (absolute, or relative to the worktree
    /// root) it is that file or nothing: the config said where the tool is. Without, the first match in `folders`.
    public func locate(_ name: String, path: String?, worktreeRoot: String) -> String? {
        if let path {
            let full = path.hasPrefix("/") ? path : worktreeRoot + "/" + path
            return Disk.isExecutable(full) ? full : nil
        }
        return folders.map { $0 + "/" + name }.first(where: Disk.isExecutable)
    }

    /// The `tool_missing` error for a tool `locate` did not find. `section` is the config section that names it.
    public static func missing(_ name: String, section: String, path: String?) -> XcdError {
        if let path {
            return XcdError(.toolMissing, "\(section).path names '\(path)', which is not a file that can be run",
                            next: "fix \(section).path in .xcdev.yml or .xcdev.local.yml, or remove it to have xcd look in PATH")
        }
        return XcdError(.toolMissing, "\(name) is not installed: it is not in PATH, \(usualFolders.joined(separator: ", or "))",
                        next: "brew install \(name), or set \(section).path in .xcdev.local.yml")
    }
}
