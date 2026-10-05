import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Whether `xcd test` is about to run UI tests, and so must stop xcd's own UI runner first.
@Suite struct UITestBundlesTests {
    let worktree = FakeWorktree(prefix: "xcd uitests")

    /// A copy of the Phone fixture: its scheme tests PhoneTests (unit tests); PhoneUITests is a UI-test bundle.
    func phone(testing uiTests: Bool) throws -> ProjectContainer {
        try Fixture.copy("ProjectFiles/Phone", to: worktree.root)
        if uiTests {
            let scheme = worktree.root + "/Phone.xcodeproj/xcshareddata/xcschemes/Phone.xcscheme"
            let text = try String(contentsOfFile: scheme, encoding: .utf8)
            let testable = """
                     <TestableReference skipped = "NO">
                        <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "A10000000000000000000103"
                           BuildableName = "PhoneUITests.xctest" BlueprintName = "PhoneUITests" ReferencedContainer = "container:Phone.xcodeproj">
                        </BuildableReference>
                     </TestableReference>
                  </Testables>
            """
            try text.replacingOccurrences(of: "      </Testables>", with: testable).write(toFile: scheme, atomically: true, encoding: .utf8)
        }
        return .project(worktree.root + "/Phone.xcodeproj")
    }

    @Test func aSchemeThatTestsOnlyUnitTestsHasNone() throws {
        defer { worktree.remove() }
        #expect(UITestBundles.included(scheme: "Phone", container: try phone(testing: false), only: [], skip: []) == false)
    }

    @Test func aUITestBundleCountsUnlessTheFiltersLeaveItOut() throws {
        defer { worktree.remove() }
        let container = try phone(testing: true)
        func included(only: [String] = [], skip: [String] = []) -> Bool? {
            UITestBundles.included(scheme: "Phone", container: container, only: only, skip: skip)
        }
        #expect(included() == true)
        #expect(included(only: ["PhoneUITests/LoginTests/testSignIn"]) == true)
        #expect(included(only: ["PhoneTests"]) == false)
        #expect(included(only: ["PhoneTests/works()"]) == false)
        #expect(included(skip: ["PhoneUITests"]) == false)
        #expect(included(skip: ["PhoneUITests/LoginTests"]) == true)            // only part of it is skipped
        #expect(included(only: ["PhoneUITestsExtra/x"]) == false)               // a different target with a longer name
    }

    @Test func whatCannotBeReadIsUnknown() throws {
        defer { worktree.remove() }
        let container = try phone(testing: true)
        func included(_ scheme: String = "Phone") -> Bool? { UITestBundles.included(scheme: scheme, container: container, only: [], skip: []) }
        #expect(included("Nope") == nil)                                        // no scheme file
        let pbxproj = worktree.root + "/Phone.xcodeproj/project.pbxproj"
        let project = try Data(contentsOf: URL(fileURLWithPath: pbxproj))
        try FileManager.default.removeItem(atPath: pbxproj)                     // the project can't be read
        #expect(included() == nil)
        try project.write(to: URL(fileURLWithPath: pbxproj))
        #expect(included() == true)
        try FixtureEdit.removeTestables(scheme: worktree.root + "/Phone.xcodeproj/xcshareddata/xcschemes/Phone.xcscheme")
        #expect(included() == nil)                                              // nothing listed, as with a test plan
    }

    @Test func aPackageHasNoneAndAWorkspaceLooksInItsProjects() throws {
        defer { worktree.remove() }
        #expect(UITestBundles.included(scheme: "Anything", container: .package(directory: worktree.root), only: [], skip: []) == false)
        try Fixture.copy("ProjectFiles/Suite", to: worktree.root)
        let workspace = ProjectContainer.workspace(worktree.root + "/Suite.xcworkspace")
        #expect(UITestBundles.schemeFile("Everything", in: workspace) == worktree.root + "/Suite.xcworkspace/xcshareddata/xcschemes/Everything.xcscheme")
        #expect(UITestBundles.schemeFile("Missing", in: workspace) == nil)
        // A scheme kept inside one of the workspace's projects is found too.
        let folder = worktree.root + "/App/App.xcodeproj/xcshareddata/xcschemes"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: worktree.root + "/Suite.xcworkspace/xcshareddata/xcschemes/Everything.xcscheme",
                                         toPath: folder + "/Inner.xcscheme")
        #expect(UITestBundles.schemeFile("Inner", in: workspace) == folder + "/Inner.xcscheme")
    }
}
