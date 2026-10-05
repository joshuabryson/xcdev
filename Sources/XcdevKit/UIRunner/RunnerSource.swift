import CryptoKit
import Foundation

/// The UI runner's source, carried in the binary (see scripts/embed-runner.sh).
public enum RunnerSource {
    public static let projectPath = "XcdRunner.xcodeproj"
    public static let scheme = "XcdRunner"
    /// xcodebuild runs a UI-test bundle inside its own runner app, whose id is the bundle's plus ".xctrunner".
    public static let runnerBundleId = "dev.xcdev.XcdRunner.xctrunner"

    /// Twelve hex digits identifying this exact source; part of the build cache's key.
    public static let hash: String = {
        var hasher = SHA256()
        for file in EmbeddedRunner.files {
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(file.contents.utf8))
            hasher.update(data: Data([0]))
        }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12))
    }()

    /// Writes the project into `directory`, creating folders as needed.
    public static func write(to directory: String) throws {
        for file in EmbeddedRunner.files {
            let path = directory + "/" + file.path
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try (file.contents + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
