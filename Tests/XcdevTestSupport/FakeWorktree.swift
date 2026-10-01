import Foundation
import XcdevKit

/// A worktree rooted at a fresh temporary directory (its path contains a space) with a FakeProcessRunner,
/// for unit-testing services that take a `WorktreeContext`: build, test, run, and logs.
/// The worktree is named "feat" in project "App", pinned to Xcode 27.0, with no simulators cloned yet.
public struct FakeWorktree: Sendable {
    public let runner: FakeProcessRunner
    /// The worktree checkout, which is also the project root. Nothing is created until `context` is called.
    public let root: String

    public init(runner: FakeProcessRunner = FakeProcessRunner(), prefix: String = "xcd worktree") {
        self.runner = runner
        root = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix) \(UUID().uuidString)").path
    }

    /// A context for `yaml` (a complete .xcdev.yml). With `container` (a path relative to `root`), also creates
    /// it: an empty file for `Package.swift`, else a directory (an .xcodeproj or .xcworkspace).
    public func context(_ yaml: String, container: String? = nil) throws -> WorktreeContext {
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        if let container {
            let path = root + "/" + container
            if container.hasSuffix("Package.swift") {
                try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                fm.createFile(atPath: path, contents: Data())
            } else {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
        }
        let state = WorktreeState(id: "id", name: "feat", project: "App", projectRoot: root, path: root, branch: "feat",
                                  xcode: XcodeInstall(path: "/Applications/Xcode.app", version: "27.0", build: "27A266a"),
                                  devices: [:], status: .ready, createdAt: Date())
        return WorktreeContext(location: ProjectLocation(projectRoot: root, worktreeRoot: root),
                               config: try ConfigLoader.parse(main: yaml), state: state)
    }

    /// A provisioner on `runner` whose global state (registry, caches, locks) lives under `root`.
    public var provisioner: DeviceProvisioner {
        DeviceProvisioner(runner: runner, globalPaths: GlobalPaths(base: root + "/home"))
    }

    public func remove() { try? FileManager.default.removeItem(atPath: root) }
}
