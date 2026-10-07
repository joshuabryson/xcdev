import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Typing can hide the keyboard it goes through: iOS takes XCTest's keys for a hardware keyboard's, minimizes the
/// software keyboard, and brings it back a moment after the typing has returned.
@Suite struct EngineKeyboardReturnTests {
    let typing = EngineTypingTests()

    static func node(_ type: Int, id: String = "", label: String = "", _ frame: ScreenRect, _ children: [SnapshotNode] = []) -> SnapshotNode {
        EngineActionsTests.node(type, id: id, label: label, frame, children)
    }

    /// The keyboard's two windows while it is minimized (seen on iOS 27.0): the placeholder is gone, and the bar
    /// and the keys sit below the 874 pt screen.
    static let minimizedWindows = [
        node(4, EngineActionsTests.screen, [node(1, EngineActionsTests.screen, [node(1, EngineActionsTests.screen)])]),
        node(4, EngineActionsTests.screen, [node(1, EngineActionsTests.screen, [node(1, ScreenRect(x: 0, y: 874, w: 402, h: 270), [
            node(1, id: "SystemInputAssistantView", ScreenRect(x: 0, y: 874, w: 402, h: 44), [node(9, ScreenRect(x: 0, y: 874, w: 134, h: 44))]),
            node(1, ScreenRect(x: 0, y: 918, w: 402, h: 226), [
                node(19, ScreenRect(x: 0, y: 918, w: 402, h: 226), [node(20, label: "Q", ScreenRect(x: 4.7, y: 925, w: 39.3, h: 54))]),
            ]),
        ])])]),
    ]

    /// The app with the keyboard up and with it minimized, from a device that can't say what has keyboard focus.
    static let shownUnknown = EngineActionsTests.appWithKeyboard
    static let minimizedUnknown = node(2, label: "SampleApp", EngineActionsTests.screen, [EngineActionsTests.form] + minimizedWindows)

    /// The same from a device that can: the field keeps keyboard focus in both (seen on iOS 27.0).
    static let shown = EngineTypingTests.reportingFocus(on: "email", shownUnknown)
    static let minimized = EngineTypingTests.reportingFocus(on: "email", minimizedUnknown)

    static let treeRequest = TreeRequest(bundleId: EngineActionsTests.bundle, system: false, all: false)

    /// A device with the keyboard up, where every key minimizes it. It is back `seconds` after the last key, or never.
    func make(keyboardBackAfter seconds: Double?, reportingFocus: Bool = true) -> (RunnerEngine, FakeDevice) {
        let shown = reportingFocus ? Self.shown : Self.shownUnknown
        let minimized = reportingFocus ? Self.minimized : Self.minimizedUnknown
        let (engine, device) = typing.base.make(shown)
        var back: Double?
        device.onGesture = { device in
            device.app = minimized
            back = seconds.map { device.clock + $0 }
        }
        device.onPause = { device in
            guard let due = back, device.clock >= due else { return }
            device.app = shown
            back = nil
        }
        return (engine, device)
    }

    @Test func typingWaitsForTheKeyboardItHidToComeBack() throws {
        let (engine, device) = make(keyboardBackAfter: 2.45)
        let result = try engine.enterText(typing.type("hi", into: nil, tree: true)).get()
        #expect(result.method == "keyboard" && device.events == ["type \"hi\""])
        #expect(result.tree?.keyboard == true && result.tree?.elements.map(\.identifier) == ["email", "signIn", "low"])
        #expect((2400...2600).contains(result.ms), "the wait is part of how long the typing took: \(result.ms) ms")
        // Without --tree as well, so the next command doesn't meet a screen whose keyboard is still away.
        _ = try engine.enterText(typing.type("more", into: nil)).get()
        #expect(try engine.tree(Self.treeRequest).get().keyboard)
    }

    /// With no word on focus, a keyboard that is away may be one the typing closed. It is waited for all the same.
    @Test func aDeviceThatCannotTellFocusWaitsForTheKeyboardToo() throws {
        let (engine, _) = make(keyboardBackAfter: 0.95, reportingFocus: false)
        let result = try engine.enterText(typing.type("hi", into: nil, tree: true)).get()
        #expect(result.tree?.keyboard == true && (900...1100).contains(result.ms), "\(result.ms) ms")
    }

    @Test func aKeyboardThatStaysAwayIsGivenUpOnAfterThreeSeconds() throws {
        let (engine, device) = make(keyboardBackAfter: nil)
        let result = try engine.enterText(typing.type("hi", into: nil, tree: true)).get()
        #expect(result.method == "keyboard" && device.events == ["type \"hi\""] && result.tree?.keyboard == false)
        #expect((2900...3100).contains(result.ms), "\(result.ms) ms")
    }

    /// Seen on iOS 27.0: Return closes a single-line field's keyboard, and nothing has keyboard focus afterwards.
    @Test func aKeyboardThatTheTypingClosedIsNotWaitedFor() throws {
        let (engine, device) = typing.base.make(Self.shown)
        device.onGesture = { $0.app = EngineTypingTests.reportingFocus(on: nil, EngineActionsTests.app) }
        let result = try engine.enterText(typing.type("hi", into: nil, submit: true, tree: true)).get()
        #expect(result.method == "keyboard" && device.events == ["type " + "hi\n".debugDescription] && result.tree?.keyboard == false)
        #expect(result.ms == 0 && device.pauses == 1, "\(result.ms) ms, \(device.pauses) pauses; the tree alone takes one")
    }

    @Test func typingThatEndsTheAppIsACrashAndWaitsForNoKeyboard() {
        let (engine, device) = typing.base.make(Self.shown)
        device.onGesture = { $0.state = .notRunning }
        guard case .failure(let crash) = engine.enterText(typing.type("hi", into: nil, tree: true)) else { Issue.record("typed"); return }
        #expect(crash.code == RunnerFailure.Code.appCrashed && crash.message == "the app is no longer running after the typing")
        #expect(device.pauses == 0, "\(device.pauses) pauses")
    }

    /// No keyboard was up before the text was pasted, so none is coming back.
    @Test func pastedTextWaitsForNoKeyboard() throws {
        let (engine, device) = typing.base.make(EngineTypingTests.reportingFocus(on: "email", EngineActionsTests.app))
        let result = try engine.enterText(typing.type("hi", into: nil)).get()
        #expect(result.method == "paste" && device.events == ["pasteboard \"hi\"", "key cmd-\"v\""])
        #expect(device.clock < 1.6, "waited \(device.clock) s; looking for a keyboard before the paste takes 1.5")
    }
}
