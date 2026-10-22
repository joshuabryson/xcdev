import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Who holds the grants and what the error says.
@Suite struct MacPermissionsTests {
    static let chain: [Int32: Int32] = [50: 40, 40: 30, 30: 1]
    static let paths: [Int32: String] = [50: "/usr/local/bin/xcd", 40: "/bin/zsh", 30: "/Applications/iTerm.app/Contents/MacOS/iTerm2"]

    @Test func theHostAppIsTheNearestAncestorInsideAnAppBundle() {
        #expect(MacHostApp.name(of: 50, parent: { Self.chain[$0] }, path: { Self.paths[$0] }) == "iTerm")
    }

    @Test func noAncestorNamesTheBinary() {
        #expect(MacHostApp.name(of: 50, parent: { $0 == 50 ? 1 : nil }, path: { Self.paths[$0] }) == "/usr/local/bin/xcd")
    }

    @Test func aMissingGrantIsPermissionMissingNamingTheAppAndThePane() {
        let api = FakeAccessibility(app: FakeApp(windows: []))
        api.setTrusted(false, capture: true)
        let read = MacPermissions.read(api: api, hostApp: "iTerm")
        let error = #expect(throws: XcdError.self) { try read.require(screenRecording: false) }
        #expect(error?.code == .permissionMissing && error?.message == "iTerm has no Accessibility permission, so xcd cannot read the app's windows")
        #expect(error?.next == MacPermissions.accessibilityNext("iTerm"))
        api.setTrusted(true, capture: false)
        let capture = #expect(throws: XcdError.self) { try MacPermissions.read(api: api, hostApp: "iTerm").require(screenRecording: true) }
        #expect(capture?.message == "iTerm has no Screen Recording permission, so xcd cannot capture the app's window")
        #expect(capture?.next?.contains("Screen & System Audio Recording") == true && capture?.next?.contains("quit and reopen") == true)
        #expect(throws: Never.self) { try MacPermissions.read(api: api, hostApp: "iTerm").require(screenRecording: false) }
        #expect(ErrorCode.permissionMissing.exitCode == 3)
    }

    /// The way out names the switch, and the grant command the user may allow.
    @Test func theNextOfAMissingGrantNamesTheSwitchAndTheGrantCommand() {
        #expect(MacPermissions.accessibilityNext("iTerm") == "in System Settings > Privacy & Security > Accessibility, turn on iTerm; "
            + "or run `xcd doctor --grant-accessibility` at the user's word. Then run the command again")
        #expect(MacPermissions.screenRecordingNext("iTerm") == "in System Settings > Privacy & Security > Screen & System Audio Recording, "
            + "turn on iTerm; or run `xcd doctor --grant-screen-recording` at the user's word. Then quit and reopen iTerm "
            + "(macOS applies that grant at launch) and run the command again")
    }

    /// The session dictionary has the key only while the screen is locked; no console session (ssh) has no dictionary.
    @Test func theScreenIsLockedOnlyWhenTheSessionSaysSo() {
        #expect(MacScreenLock.isLocked(session: ["CGSSessionScreenIsLocked": 1, "kCGSSessionOnConsoleKey": 1]))
        #expect(!MacScreenLock.isLocked(session: ["CGSSessionScreenIsLocked": 0]))
        #expect(!MacScreenLock.isLocked(session: ["kCGSSessionOnConsoleKey": 1]) && !MacScreenLock.isLocked(session: nil))
    }
}
