import Foundation

public enum Paths {
    /// Absolute, standardized, symlink-resolved path. Note that Foundation strips the
    /// `/private` prefix (e.g. `/private/var` → `/var`), so always compare canonical paths.
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public enum Shell {
    /// POSIX single-quote a string for display in `next:` hints and command lines.
    public static func quote(_ s: String) -> String {
        let special = " \t\n\"'$\\`!*?[](){};&|<>#~"
        guard s.isEmpty || s.contains(where: { special.contains($0) }) else { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
