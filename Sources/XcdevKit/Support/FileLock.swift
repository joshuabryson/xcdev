import Foundation

public enum FileLock {
    /// Exclusive advisory lock (flock) held for the duration of `body`. Works across processes and,
    /// because each call opens its own file descriptor, across tasks in the same process.
    public static func withLock<T: Sendable>(at path: String, _ body: () async throws -> T) async throws -> T {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw XcdError(.internalError, "cannot open lock file \(path) (errno \(errno))")
        }
        defer { close(fd) }
        let lockErrno = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global().async {
                while true {
                    if flock(fd, LOCK_EX) == 0 {
                        continuation.resume(returning: 0)
                        return
                    }
                    let code = errno
                    if code != EINTR {
                        continuation.resume(returning: code)
                        return
                    }
                }
            }
        }
        guard lockErrno == 0 else {
            throw XcdError(.internalError, "cannot lock \(path) (errno \(lockErrno): \(String(cString: strerror(lockErrno))))")
        }
        defer { flock(fd, LOCK_UN) }
        return try await body()
    }

    /// Like `withLock`, but never waits: returns nil without running `body` when someone else holds the lock.
    /// Doctor uses it for a worktree's lock, which a `wt create` or `wt remove` holds for up to 30 minutes.
    public static func withLockIfFree<T: Sendable>(at path: String, _ body: () async throws -> T) async throws -> T? {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw XcdError(.internalError, "cannot open lock file \(path) (errno \(errno))")
        }
        defer { close(fd) }
        var lockErrno: Int32 = 0
        repeat {
            lockErrno = flock(fd, LOCK_EX | LOCK_NB) == 0 ? 0 : errno
        } while lockErrno == EINTR
        if lockErrno == EWOULDBLOCK { return nil }
        guard lockErrno == 0 else {
            throw XcdError(.internalError, "cannot lock \(path) (errno \(lockErrno): \(String(cString: strerror(lockErrno))))")
        }
        defer { flock(fd, LOCK_UN) }
        return try await body()
    }

    /// Whether someone holds the lock at `path` right now. Never waits, and never creates the file (doctor
    /// without --fix writes nothing). A lock taken just after this returns false is missed, so a caller that acts
    /// on false must still take the lock before changing anything.
    public static func isHeld(at path: String) -> Bool {
        let fd = open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return false }          // never created, so never held
        defer { close(fd) }
        var code: Int32 = 0
        repeat {
            code = flock(fd, LOCK_EX | LOCK_NB) == 0 ? 0 : errno
        } while code == EINTR
        guard code == 0 else { return code == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
    }
}
