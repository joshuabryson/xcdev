import Testing
@testable import XcdevKit

/// A worktree's name as the suffix of its Mac copy's bundle id.
@Suite struct MacBundleSlugTests {
    @Test(arguments: [("Feature/Login α", "feature-login"), ("MAIN", "main"), ("--", "worktree"), ("...", "worktree"),
                      ("", "worktree"), ("a  b", "a-b"), ("wt-1", "wt-1")])
    func namesBecomeLowercaseHyphenatedSlugs(name: String, slug: String) {
        #expect(MacBundleSlug.slug(name) == slug)
    }

    @Test func bundleIdAppendsTheSuffix() {
        #expect(MacBundleSlug.bundleId("dev.x.Mac", worktreeName: "Feature/Login α") == "dev.x.Mac.xcd-feature-login")
        #expect(MacBundleSlug.bundleId("dev.x.Mac", worktreeName: "...") == "dev.x.Mac.xcd-worktree")
    }
}
