import Foundation

/// The engine's ref table between two xcd commands on a Mac: xcd exits after each, unlike the runner.
public struct MacRefs: Codable, Sendable, Equatable {
    public var refs: [String: RefSignature]
    public var lastRef: Int

    public init(refs: [String: RefSignature], lastRef: Int) {
        self.refs = refs
        self.lastRef = lastRef
    }
}

public enum MacRefStore {
    public static func file(_ paths: WorktreePaths, device: String) -> String { paths.stateDirectory + "/ui-mac-\(device).json" }

    /// A file that is missing or unreadable is an empty table: every old ref is then unknown, which is the safe answer.
    public static func load(_ file: String) -> MacRefs {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
              let refs = try? JSONCoding.decoder.decode(MacRefs.self, from: data) else { return MacRefs(refs: [:], lastRef: 0) }
        return refs
    }

    public static func save(_ refs: MacRefs, to file: String) throws {
        try Disk.makeFolder((file as NSString).deletingLastPathComponent)
        try JSONCoding.encoder(pretty: true).encode(refs).write(to: URL(fileURLWithPath: file), options: .atomic)
    }

    public static func forget(_ file: String) { Disk.remove(file) }

    /// Every device's refs in the worktree: a launch makes them all stale. Only the state folder's own level is
    /// listed: `.xcdev/DerivedData` below it can hold tens of thousands of files.
    public static func forgetAll(in paths: WorktreePaths) {
        for name in Disk.names(in: paths.stateDirectory) where name.hasPrefix("ui-mac-") && name.hasSuffix(".json") {
            Disk.remove(paths.stateDirectory + "/" + name)
        }
    }
}
