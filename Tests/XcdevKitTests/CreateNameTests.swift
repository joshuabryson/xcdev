import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd wt create <name>` and names that belong to other checkouts.
@Suite struct CreateNameTests {
    let hooks = PendingHookTests()

    /// The service, the main checkout's context, and the path of a plain worktree first used as `feature`.
    func opened(_ project: TempProject) async throws -> (WorktreeService, WorktreeContext, String) {
        let other = try hooks.worktree(project)
        let svc = hooks.service(project)
        _ = try await svc.open(from: other)
        return (svc, try await svc.open(from: project.root), other)
    }

    @Test func createWillNotHandBackAnotherToolsCheckoutOrAnEntryThatDiffersOnlyInCase() async throws {
        let project = try TempProject.make(config: PendingHookTests.config)
        defer { project.remove() }
        let (svc, main, other) = try await opened(project)

        let foreign = await #expect(throws: XcdError.self) { try await svc.create(name: "feature", in: main) }
        #expect(foreign?.code == .usage && foreign?.next?.contains("ask the user before working in " + other) == true)
        #expect(FileManager.default.fileExists(atPath: other + "/.xcdev/worktree.json"))

        let made = try await svc.create(name: "made", in: main)
        let again = try await svc.create(name: "made", in: main)
        #expect(!again.created && again.state.path == made.state.path)
        let cased = await #expect(throws: XcdError.self) { try await svc.create(name: "Made", in: main) }
        #expect(cased?.code == .usage && cased?.next == "pick another name")
    }

    @Test func anyCaseOfMainIsTakenAndAGoneForeignCheckoutSaysHowToDropIt() async throws {
        let project = try TempProject.make(config: PendingHookTests.config)
        defer { project.remove() }
        let (svc, main, other) = try await opened(project)
        let named = await #expect(throws: XcdError.self) { try await svc.create(name: "Main", in: main) }
        #expect(named?.code == .usage && named?.message == "'Main' is the main checkout's name but for case" && named?.next == "pick another name")
        try FileManager.default.removeItem(atPath: other)
        let gone = await #expect(throws: XcdError.self) { try await svc.create(name: "feature", in: main) }
        #expect(gone?.next == "run `xcd wt remove feature` to drop xcd's record of the checkout that was at \(other), or pick another name")
    }
}
