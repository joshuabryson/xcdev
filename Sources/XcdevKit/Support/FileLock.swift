import Foundation
import Synchronization

public enum FileLock {
    /// How many in this process wait for each lock, by path.
    private static let waiting = Mutex<[String: Int]>([:])

    /// Whether a `withLock` or `hold` in this process is waiting for the lock at `path`, which someone else has, so
    /// that a test holding a lock as another xcd would sees at once what waits for it.
    public static func isAwaited(at path: String) -> Bool {
        waiting.withLock { $0[path, default: 0] > 0 }
    }

    /// `flock`, tried again when a signal interrupts it. Returns 0, or the errno that stopped it.
    private static func attempt(_ operation: Int32, on fd: Int32) -> Int32 {
        var code: Int32 = 0
        repeat {
            code = flock(fd, operation) == 0 ? 0 : errno
        } while code == EINTR
        return code
    }

    /// Takes the lock (`LOCK_EX` or `LOCK_SH`) on `fd`. While someone else has it this waits off the threads that run
    /// Swift tasks, counted among the lock's waiters. Returns 0, or the errno that stopped it.
    private static func take(_ operation: Int32, on fd: Int32, at path: String) async -> Int32 {
        let first = attempt(operation | LOCK_NB, on: fd)
        guard first == EWOULDBLOCK else { return first }
        waiting.withLock { $0[path, default: 0] += 1 }
        defer {
            waiting.withLock { counts in
                let left = counts[path, default: 1] - 1
                counts[path] = left > 0 ? left : nil
            }
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: attempt(operation, on: fd)) }
        }
    }

    /// Makes the lock file's folder and opens the file, close-on-exec.
    private static func openLockFile(at path: String) throws -> Int32 {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw XcdError(.internalError, "cannot open lock file \(path) (errno \(errno))")
        }
        return fd
    }

    /// Exclusive advisory lock (flock) held for the duration of `body`. Works across processes and,
    /// because each call opens its own file descriptor, across tasks in the same process.
    public static func withLock<T: Sendable>(at path: String, _ body: () async throws -> T) async throws -> T {
        let fd = try openLockFile(at: path)
        defer { close(fd) }
        let lockErrno = await take(LOCK_EX, on: fd, at: path)
        guard lockErrno == 0 else {
            throw XcdError(.internalError, "cannot lock \(path) (errno \(lockErrno): \(String(cString: strerror(lockErrno))))")
        }
        defer { flock(fd, LOCK_UN) }
        return try await body()
    }

    /// A shared lock held until `release`: many holders at once, and an exclusive try (`withLockIfFree`) finds the
    /// file held while any one of them is. Waits while an exclusive holder has it. A lock file this user cannot make,
    /// open, or lock fails with a `next:` naming its folder (`unusable`).
    public static func hold(at path: String) async throws -> Int32 {
        do {
            try Disk.makeFolder((path as NSString).deletingLastPathComponent)
        } catch {
            throw unusable(path, "cannot make the folder of lock file \(path)", details: [error.localizedDescription])
        }
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw unusable(path, "cannot open lock file \(path) (\(describe(errno)))") }
        let lockErrno = await take(LOCK_SH, on: fd, at: path)
        guard lockErrno == 0 else {
            close(fd)
            throw unusable(path, "cannot lock \(path) (\(describe(lockErrno)))")
        }
        return fd
    }

    /// A lock file `hold` cannot use, most often because a `sudo xcd` left its folder owned by root. `next:` names the
    /// nearest folder that exists: the lock's own, or the one above it that could not be written into.
    static func unusable(_ path: String, _ message: String, details: [String] = []) -> XcdError {
        var folder = (path as NSString).deletingLastPathComponent
        while !Disk.exists(folder), folder.count > 1 { folder = (folder as NSString).deletingLastPathComponent }
        return XcdError(.internalError, message,
                        next: "check that \(folder) and its files belong to you and are writable (a `sudo xcd` can leave "
                            + "them owned by root): `ls -l \(Shell.quote(folder))`",
                        details: details)
    }

    private static func describe(_ code: Int32) -> String {
        "errno \(code): \(String(cString: strerror(code)))"
    }

    /// Lets go of a lock `hold` returned.
    public static func release(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
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
        let lockErrno = attempt(LOCK_EX | LOCK_NB, on: fd)
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
        let code = attempt(LOCK_EX | LOCK_NB, on: fd)
        guard code == 0 else { return code == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
    }
}
