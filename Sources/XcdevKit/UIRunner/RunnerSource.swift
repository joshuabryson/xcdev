import CryptoKit
import Foundation

/// The UI runner's source, carried in the binary (see scripts/embed-runner.sh).
public enum RunnerSource {
    public static let projectPath = "XcdRunner.xcodeproj"
    public static let scheme = "XcdRunner"
    /// xcodebuild runs a UI-test bundle inside its own runner app, whose id is the bundle's plus ".xctrunner".
    public static let runnerBundleId = "dev.xcdev.XcdRunner.xctrunner"

    static let unreadable = XcdError(.internalError, "the embedded UI runner source is unreadable",
                                     next: "this is a bug in xcd; please report it")

    /// The embedded files, or the reason they could not be read.
    static let embedded: Result<[(path: String, contents: Data)], XcdError> = {
        do { return .success(try decode(EmbeddedRunner.archive)) } catch { return .failure(unreadable) }
    }()

    /// Twelve hex digits identifying this exact source; part of the build cache's key.
    public static let hash: String = {
        guard case .success(let files) = embedded else { return "unreadable" }
        var hasher = SHA256()
        for file in files {
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: file.contents)
            hasher.update(data: Data([0]))
        }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12))
    }()

    /// Writes the project into `directory`, creating folders as needed.
    public static func write(to directory: String) throws {
        for file in try embedded.get() {
            let path = directory + "/" + file.path
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try file.contents.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// Unpacks an archive: base64, then gzip, then `path NUL byteCount NUL bytes` repeated.
    static func decode(_ archive: String) throws -> [(path: String, contents: Data)] {
        let text = String(archive.filter { !$0.isWhitespace })
        guard let packed = Data(base64Encoded: text), let container = gunzip(packed) else { throw unreadable }
        return try parse(container)
    }

    /// A `gzip -n` stream is a 10-byte header (no optional fields), raw DEFLATE, and an 8-byte trailer.
    private static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08, bytes[3] == 0 else { return nil }
        let deflated = Data(bytes[10..<(bytes.count - 8)])
        return try? (deflated as NSData).decompressed(using: .zlib) as Data
    }

    /// A relative path that stays inside the directory it is written to.
    private static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    static func parse(_ container: Data) throws -> [(path: String, contents: Data)] {
        let bytes = [UInt8](container)
        var files: [(path: String, contents: Data)] = []
        var position = 0
        func field() -> String? {
            guard let end = bytes[position...].firstIndex(of: 0) else { return nil }
            defer { position = end + 1 }
            return String(bytes: bytes[position..<end], encoding: .utf8)
        }
        while position < bytes.count {
            guard let path = field(), isSafe(path), let count = field().flatMap({ Int($0) }), count >= 0, bytes.count - position >= count else {
                throw unreadable
            }
            files.append((path, Data(bytes[position..<(position + count)])))
            position += count
        }
        return files
    }
}
