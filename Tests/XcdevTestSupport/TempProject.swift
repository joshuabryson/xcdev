import Foundation
import XcdevKit

/// A throwaway git repo (default name contains a space) with a committed .xcdev.yml.
public struct TempProject: Sendable {
    public let base: String
    /// Canonical path of the main checkout.
    public let root: String
    /// Use as GlobalPaths base (XCDEV_HOME) so tests never touch the real registry.
    public let home: String

    public static func make(config: String, name: String = "Sample App") throws -> TempProject {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("xcdev-tests-\(UUID().uuidString)").path
        let root = base + "/" + name
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try config.write(toFile: root + "/.xcdev.yml", atomically: true, encoding: .utf8)
        try "hello\n".write(toFile: root + "/README.md", atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], in: root)
        try git(["add", "."], in: root)
        try git(["-c", "user.name=xcd", "-c", "user.email=xcd@example.com", "commit", "-q", "-m", "Initial"], in: root)
        return TempProject(base: base, root: Paths.canonical(root), home: base + "/home")
    }

    public func remove() { try? FileManager.default.removeItem(atPath: base) }

    public func write(_ contents: String, to relativePath: String, in directory: String? = nil) throws {
        let path = (directory ?? root) + "/" + relativePath
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    public static func git(_ args: [String], in directory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XcdError(.internalError, "git \(args.joined(separator: " ")) failed in \(directory)")
        }
    }
}
