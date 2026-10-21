import CoreGraphics
import Foundation

/// Whether the Mac's screen is locked. While it is, a hidden app's Accessibility windows collapse into one that
/// lists the application under itself, so no tree read there means anything (measured 2026-10-20).
public enum MacScreenLock {
    /// The login session's dictionary has this key, set to 1, only while the screen is locked.
    static let lockedKey = "CGSSessionScreenIsLocked"

    /// The one refusal of a Mac `ui` command, screenshot, or recording while the screen is locked.
    public static let refusal = XcdError(.runnerFailed, "the Mac's screen is locked, so the app's windows cannot be read",
                                         next: "ask the user to unlock the Mac, then run the command again")

    public static func isLocked() -> Bool { isLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any]) }

    /// No session dictionary (no console session, as over ssh) is not a locked screen.
    static func isLocked(session: [String: Any]?) -> Bool {
        (session?[lockedKey] as? NSNumber)?.boolValue == true
    }
}
