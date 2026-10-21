import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// What a Mac `ui` command keeps between commands, and what it says with no build.
@Suite struct UIServiceMacSessionTests {
    let base = UIServiceMacTests()

    /// Each command is a new engine. The ref table and the number of the last ref given out are saved between them,
    /// so an element that appears later gets the next number and the old elements keep theirs.
    @Test func refNumbersCarryOnFromOneCommandToTheNext() async throws {
        defer { base.worktree.remove() }
        let api = FakeAccessibility(app: UIServiceMacTests.app)
        var (service, ctx) = try base.setup(api)
        let first = try await service.tree(all: false, base.options, in: &ctx)
        let refs = first.tree.elements.compactMap(\.ref)
        let last = try #require(refs.compactMap { Int($0.dropFirst()) }.max())
        api.addToFirstWindow(FakeNode(role: "AXButton", title: "Reset", identifier: "reset", frame: ScreenRect(x: 2574, y: 400, w: 85, h: 24),
                                      actions: ["AXPress"]))
        let second = try await service.tree(all: false, base.options, in: &ctx)
        #expect(second.tree.elements.first { $0.identifier == "reset" }?.ref == "e\(last + 1)")
        #expect(second.tree.elements.filter { $0.identifier != "reset" }.map(\.ref) == first.tree.elements.map(\.ref))
    }

    /// With no build record and no `--bundle`, the error says what names an app on a Mac: `--system` does not, since
    /// a Mac has no Home Screen. A command that finds this through the bundle id and one that finds it through the
    /// app's process say it alike.
    @Test func aMacWithNoBuildSaysToRunTheAppOrNameOneWithBundle() async throws {
        defer { base.worktree.remove() }
        var (service, ctx) = try base.setup(FakeAccessibility(app: UIServiceMacTests.app))
        try AppStateStore.save(AppState(), ctx.paths)
        let tap = await #expect(throws: XcdError.self) { try await service.tap("id:increment", base.options, in: &ctx) }
        #expect(tap?.code == .appNotBuilt && tap?.message == "no app has been built for mac in this worktree")
        #expect(tap?.next == "build and start it with `xcd run --device mac` first, or name a running app with `--bundle <id>`")
        let tree = await #expect(throws: XcdError.self) { try await service.tree(all: false, base.options, in: &ctx) }
        let button = await #expect(throws: XcdError.self) { try await service.button("home", base.options, in: &ctx) }
        #expect(tree?.next == tap?.next && button?.code == .appNotBuilt && button?.next == tap?.next)
    }
}
