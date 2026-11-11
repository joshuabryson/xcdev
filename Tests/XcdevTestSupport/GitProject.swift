import Foundation
import XcdevKit

/// Git steps on a `TempProject`, for tests that need commits, branches, and remote branches.
extension TempProject {
    /// Stages everything and commits it. Returns the commit.
    @discardableResult
    public func commit(_ message: String = "Change", in directory: String? = nil) throws -> String {
        let at = directory ?? root
        try Self.git(["add", "-A"], in: at)
        try Self.git(["-c", "user.name=xcd", "-c", "user.email=xcd@example.com", "commit", "-q", "--allow-empty", "-m", message], in: at)
        return try rev("HEAD", in: at)
    }

    /// The commit `ref` names.
    public func rev(_ ref: String, in directory: String? = nil) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: Self.gitExecutable)
        process.arguments = ["-C", directory ?? root, "rev-parse", ref]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XcdError(.internalError, "git rev-parse \(ref) failed") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func git(_ arguments: String...) throws {
        try Self.git(arguments, in: root)
    }
}
