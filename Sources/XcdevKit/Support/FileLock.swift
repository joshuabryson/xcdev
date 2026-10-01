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
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
                continuation.resume()
            }
        }
        defer { flock(fd, LOCK_UN) }
        return try await body()
    }
}
