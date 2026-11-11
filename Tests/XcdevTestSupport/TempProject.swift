import Foundation
import XcdevKit

/// A throwaway git repo (default name contains a space) with a committed .xcdev.yml.
public struct TempProject: Sendable {
    public let base: String
    /// Canonical path of the main checkout.
    public let root: String
    /// Use as GlobalPaths base (XCDEV_HOME) so tests never touch the real registry.
    public let home: String

    /// `fixture`: a directory whose contents are copied in before the first commit. `parent`: where the throwaway
    /// directory goes (default: the temp directory; simulator app output needs somewhere outside it).
    public static func make(config: String, name: String = "Sample App", fixture: String? = nil,
                            parent: String? = nil) throws -> TempProject {
        let fm = FileManager.default
        let base = (parent ?? fm.temporaryDirectory.path) + "/xcdev-tests-\(UUID().uuidString)"
        let root = base + "/" + name
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        if let fixture {
            for item in try fm.contentsOfDirectory(atPath: fixture) {
                try fm.copyItem(atPath: fixture + "/" + item, toPath: root + "/" + item)
            }
        }
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

    /// A folder that `XcodeDiscovery.readInstall` takes for an Xcode, named `name` under the temporary folder.
    public func standInXcode(_ name: String, version: String) throws -> String {
        let path = base + "/" + name + ".app"
        let info = ["CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundleShortVersionString": version]
        try write("", to: "Contents/Info.plist", in: path)
        try (info as NSDictionary).write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// git itself, found once. `/usr/bin/git` stands in for it and asks xcrun where it is on every call, which in a
    /// test's dozens of calls costs more than git's own work. git names its `<developer>/usr/libexec/git-core`
    /// folder; it is `<developer>/usr/bin/git`.
    static let gitExecutable: String = {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--exec-path"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "/usr/bin/git" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let core = URL(fileURLWithPath: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        let git = core.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin/git").path
        return process.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: git) ? git : "/usr/bin/git"
    }()

    /// Runs git in `directory`, with no maintenance after a commit: a test's repo never needs it, and it is a process
    /// more per commit.
    public static func git(_ args: [String], in directory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitExecutable)
        process.arguments = ["-c", "maintenance.auto=false", "-C", directory] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XcdError(.internalError, "git \(args.joined(separator: " ")) failed in \(directory)")
        }
    }
}
