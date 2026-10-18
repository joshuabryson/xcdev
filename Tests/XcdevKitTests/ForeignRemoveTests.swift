import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd wt remove` of a checkout xcd did not make removes only xcd's part.
@Suite struct ForeignRemoveTests {
    static let config = PendingHookTests.config + """

      pre-worktree-remove: 'echo "$XCD_HOOK" >> "$XCD_PROJECT_ROOT/../runs.log"'
    """

    let hooks = PendingHookTests()

    @Test func itsClonesAndStateGoAndTheCheckoutItsBranchAndItsChangesStay() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        hooks.fake.stub(["xcrun", "simctl"])
        let svc = hooks.service(project)
        let main = try await svc.open(from: project.root)
        let path = try hooks.worktree(project)
        var state = try await svc.open(from: path).state
        state.devices["iphone"] = ProvisionedDevice(udid: "UDID-1", deviceType: "iPhone 18 Pro", deviceTypeIdentifier: "t",
                                                    runtime: "iOS 27.0", runtimeIdentifier: "r")
        try WorktreeStateStore.save(state, WorktreePaths(root: path))
        try project.write("draft\n", to: "Notes.md", in: path)
        try TempProject.git(["switch", "-q", "-c", "renamed"], in: path)

        let removal = try await svc.remove(name: "feature", in: main)
        #expect(removal.keptCheckout && removal.removedDevices == ["iphone"])
        #expect(hooks.fake.commandLines.contains("xcrun simctl delete UDID-1"))
        #expect(FileManager.default.fileExists(atPath: path + "/Notes.md"))
        #expect(!FileManager.default.fileExists(atPath: path + "/.xcdev"))
        try TempProject.git(["rev-parse", "--verify", "--quiet", "refs/heads/wt-feature"], in: project.root)
        #expect(try svc.list(projectRoot: project.root).map(\.name) == ["main"])
        #expect(hooks.runs(project) == ["post-worktree-create feature"])            // no pre-worktree-remove
        #expect(removal.text == """
        removed xcd's state for feature  devices=iphone
        the checkout at \(path) and its branch renamed are left to whatever made them
        """)
    }

    @Test func xcdsOwnWorktreeIsStillRemovedWithItsCheckout() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let svc = hooks.service(project)
        let main = try await svc.open(from: project.root)
        let made = try await svc.create(name: "made", in: main)
        let removal = try await svc.remove(name: "made", in: main)
        #expect(!removal.keptCheckout && !FileManager.default.fileExists(atPath: made.state.path))
        #expect(hooks.runs(project) == ["post-worktree-create made", "pre-worktree-remove"])
    }

    @Test func aCheckoutOnADetachedHeadIsNotGivenABranch() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let svc = hooks.service(project)
        let main = try await svc.open(from: project.root)
        let path = Paths.canonical(project.base + "/wt/detached")
        try TempProject.git(["worktree", "add", "-q", "--detach", path], in: project.root)
        let name = try await svc.open(from: path).state.name
        let removal = try await svc.remove(name: name, in: main)
        #expect(removal.keptCheckout && removal.branch == nil)
        #expect(removal.text.hasSuffix("the checkout at \(path), on a detached HEAD, is left to whatever made it"))
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func aCheckoutNestedInsideAnXcdWorktreeIsNotXcds() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let svc = hooks.service(project)
        let main = try await svc.open(from: project.root)
        let made = try await svc.create(name: "made", in: main)
        let nested = Paths.canonical(made.state.path + "/.claude/worktrees/x")
        try TempProject.git(["worktree", "add", "-q", "-b", "nested", nested], in: project.root)
        _ = try await svc.open(from: nested)
        let removal = try await svc.remove(name: "x", in: main)
        #expect(removal.keptCheckout)
        #expect(FileManager.default.fileExists(atPath: nested))
    }

    @Test func aKeptCheckoutWhoseFolderIsGoneSaysSo() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let svc = hooks.service(project)
        let main = try await svc.open(from: project.root)
        let path = try hooks.worktree(project)
        _ = try await svc.open(from: path)
        try FileManager.default.removeItem(atPath: path)
        let removal = try await svc.remove(name: "feature", in: main)
        #expect(removal.keptCheckout && removal.checkoutGone)
        #expect(removal.text.split(separator: "\n").map(String.init)[1] == "the checkout at \(path) was already gone")
    }
}
