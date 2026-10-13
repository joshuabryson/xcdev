import CryptoKit
import Foundation

/// What a set of files held at one moment, kept to tell afterwards which of them a command rewrote: a project's own
/// format command says nothing about what it changed.
struct FileStamps: Sendable {
    /// Each path, relative to the root, with a digest of its bytes. A path that could not be read has none.
    let digests: [String: SHA256.Digest]
    let paths: [String]

    init(of paths: [String], in root: String) {
        self.paths = paths
        var digests: [String: SHA256.Digest] = [:]
        for path in paths { digests[path] = Self.digest(root + "/" + path) }
        self.digests = digests
    }

    /// The paths whose bytes differ now, in the order they were given. A file that is gone, or that is there now and
    /// was not, differs. A file written again with the same bytes does not.
    func changed(in root: String) -> [String] {
        paths.filter { Self.digest(root + "/" + $0) != digests[$0] }
    }

    static func digest(_ path: String) -> SHA256.Digest? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).map { SHA256.hash(data: $0) }
    }
}
