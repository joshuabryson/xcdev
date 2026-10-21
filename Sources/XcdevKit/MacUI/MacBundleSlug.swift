/// A worktree's name as the suffix that gives its Mac copy a bundle id of its own.
public enum MacBundleSlug {
    /// The name lowercased, each run of characters other than a-z and 0-9 one "-", no "-" at either end, and
    /// "worktree" when nothing is left: `Feature/Login α` → `feature-login`.
    public static func slug(_ worktreeName: String) -> String {
        var slug = ""
        for scalar in worktreeName.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug += "-"
            }
        }
        if slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "worktree" : slug
    }

    /// `base` with the worktree's suffix: `dev.x.Mac` in `Feature/Login` → `dev.x.Mac.xcd-feature-login`.
    public static func bundleId(_ base: String, worktreeName: String) -> String {
        base + ".xcd-" + slug(worktreeName)
    }
}
