import Darwin
import Foundation

/// The two grants a Mac `ui` command needs, and whose they are.
public struct MacPermissions: Sendable, Equatable {
    public let accessibility: Bool
    public let screenRecording: Bool
    /// The app macOS attributes xcd's grants to.
    public let hostApp: String

    public static func read(api: any AccessibilityAPI, hostApp: String) -> MacPermissions {
        MacPermissions(accessibility: api.isTrusted, screenRecording: api.screenCaptureAllowed, hostApp: hostApp)
    }

    /// The one `next:` for a missing grant, shared with the doctor check and the grant command's failure: the switch by
    /// hand, or `xcd doctor --grant-…` at the user's word.
    public static func accessibilityNext(_ app: String) -> String {
        "in System Settings > Privacy & Security > Accessibility, turn on \(app); or run `xcd doctor --grant-accessibility` "
            + "at the user's word. Then run the command again"
    }
    public static func screenRecordingNext(_ app: String) -> String {
        "in System Settings > Privacy & Security > Screen & System Audio Recording, turn on \(app); or run "
            + "`xcd doctor --grant-screen-recording` at the user's word. Then quit and reopen \(app) (macOS applies that grant "
            + "at launch) and run the command again"
    }

    public func require(screenRecording needed: Bool) throws {
        guard accessibility else {
            throw XcdError(.permissionMissing, "\(hostApp) has no Accessibility permission, so xcd cannot read the app's windows",
                           next: Self.accessibilityNext(hostApp))
        }
        guard !needed || screenRecording else {
            throw XcdError(.permissionMissing, "\(hostApp) has no Screen Recording permission, so xcd cannot capture the app's window",
                           next: Self.screenRecordingNext(hostApp))
        }
    }
}

/// The nearest ancestor of a process whose executable is inside an app bundle: that is who macOS asks for the grants.
public enum MacHostApp {
    public static func name(of pid: Int32, parent: (Int32) -> Int32?, path: (Int32) -> String?) -> String {
        var current: Int32? = pid
        for _ in 0..<64 {
            guard let pid = current, pid > 1 else { break }
            if let found = path(pid).flatMap(bundleName) { return found }
            current = parent(pid)
        }
        return path(pid) ?? "the process that runs xcd"
    }

    /// "iTerm" from "/Applications/iTerm.app/Contents/MacOS/iTerm2".
    static func bundleName(_ path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/MacOS/") else { return nil }
        return (String(path[..<range.lowerBound]) as NSString).lastPathComponent
    }

    public static func live() -> String { name(of: getpid(), parent: parentPid, path: executablePath) }

    /// Through `sysctl`, as `ps` reads it: `proc_pidinfo` answers EPERM to a user process about root's processes, and
    /// Terminal and iTerm2 run their shells under a root-owned `login`, so the walk used to stop there. Nil when no
    /// process has the pid (`sysctl` then answers with no bytes).
    static func parentPid(_ pid: Int32) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func executablePath(_ pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE, a macro Swift does not import.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))       // the path's bytes, without the terminating 0
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}
