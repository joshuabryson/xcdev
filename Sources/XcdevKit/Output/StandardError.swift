import Foundation

/// Writes to stderr that never fail loudly. `FileHandle.standardError.write(_:)` raises an Objective-C exception,
/// which aborts xcd, when stderr is closed (EBADF) or its terminal is gone (EIO); a broken pipe gives EPIPE once
/// the CLI ignores SIGPIPE. xcd's progress and interrupt lines are best effort, so a failed write is dropped.
public enum StandardError {
    public static func write(_ text: String) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
            if written > 0 {
                bytes = bytes.dropFirst(written)
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}
