import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// git in the tests' throwaway repos reads only each repo's own config: the person's global and system settings
/// (hooks above all, which run on every commit and checkout) neither slow the tests nor run in them.
@Suite struct IsolatedGitTests {
    @Test func gitInATestRepoReadsOnlyTheReposOwnConfig() async throws {
        let project = try TempProject.make(config: "version: 1\nproject: App.xcodeproj\n")
        defer { project.remove() }
        let out = try await SystemProcessRunner().runChecked(Invocation("/usr/bin/git", ["-C", project.root, "config", "--list", "--show-scope"]))
        // Named by scope and key only: a value from the person's own config (their email) has no place in a test log.
        let foreign = out.stdoutString.split(separator: "\n").filter { !$0.hasPrefix("local\t") }.map { $0.prefix { $0 != "=" } }
        #expect(foreign.isEmpty, "\(foreign)")
    }
}
