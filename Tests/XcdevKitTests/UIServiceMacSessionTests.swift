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

    /// `AXShowMenu` opens the context menu on the person's screen, hidden app or not (measured 2026-10-20: a menu window
    /// at the pop-up menu level, opaque, until an item was pressed), so a long-press on a Mac is refused before any
    /// session is built: nothing is read, pressed, or looked up.
    @Test func aLongPressIsRefusedOnAMacBeforeAnythingIsRead() async throws {
        defer { base.worktree.remove() }
        let api = FakeAccessibility(app: UIServiceMacTests.app)
        var (service, ctx) = try base.setup(api)
        let refused = await #expect(throws: XcdError.self) {
            try await service.longPress("id:increment", duration: .seconds(1), base.options, in: &ctx)
        }
        #expect(refused?.code == .platformUnsupported)
        #expect(refused?.message == "a long-press opens the element's context menu on the person's screen (a visible menu window until one of its items is pressed)")
        #expect(refused?.next == "use `xcd ui menu \"<Menu> > <Item>\"` for the app's commands; a flag that allows a visible context menu is a follow-up")
        #expect(api.events.isEmpty && !base.worktree.runner.calls.contains { $0.argv[0] == "ps" })
        #expect(!FileManager.default.fileExists(atPath: MacRefStore.file(ctx.paths, device: "mac")))
    }

    @Test func menuListsAndPressesOnAMacAndIsRefusedOnASimulator() async throws {
        defer { base.worktree.remove() }
        var app = UIServiceMacTests.app
        app.menuBar = MacMenuTests.menuBar
        let api = FakeAccessibility(app: app)
        var (service, ctx) = try base.setup(api)
        let listed = try await service.menu(nil, base.options, in: &ctx)
        #expect(listed.text.contains("File > Save… (disabled)") && listed.text.contains("Probe > Bump by ten"))
        var withTree = base.options
        withTree.tree = true
        let pressed = try await service.menu("Probe > Bump by ten", withTree, in: &ctx)
        #expect(pressed.text.hasPrefix("pressed Probe > Bump by ten") && pressed.tree != nil && api.events.contains("AXPress Bump by ten"))
        var phone = base.options
        phone.device = "iphone"
        let refused = await #expect(throws: XcdError.self) { try await service.menu(nil, phone, in: &ctx) }
        #expect(refused?.code == .platformUnsupported)
    }

    /// The press has happened when `--tree` reads the tree, so a read that fails is a note in the text and the JSON, as
    /// after any action, and not a tree that is silently missing.
    @Test func aMenuPressWhoseTreeCannotBeReadSaysSo() async throws {
        defer { base.worktree.remove() }
        var app = UIServiceMacTests.app
        app.menuBar = MacMenuTests.menuBar
        let api = FakeAccessibility(app: app)
        var (service, ctx) = try base.setup(api)
        var withTree = base.options
        withTree.tree = true
        api.loseWindowList(forReads: 10)
        let pressed = try await service.menu("Probe > Bump by ten", withTree, in: &ctx)
        let note = "note: the tree could not be read after the action; run `xcd ui tree`"
        #expect(api.events == ["AXPress Bump by ten"] && pressed.tree == nil && pressed.notes == [note])
        #expect(pressed.text == "pressed Probe > Bump by ten\n" + note)
        #expect(String(decoding: try JSONEncoder().encode(pressed), as: UTF8.self).contains("\"notes\":[\"\(note)\"]"))
    }
}
