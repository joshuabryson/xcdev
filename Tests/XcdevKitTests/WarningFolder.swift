import Foundation
import Testing
@testable import XcdevKit

/// A folder of source files in the temporary directory, for the tests of the warnings xcd keeps.
struct WarningFolder {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("xcd warnings \(UUID().uuidString)").path

    /// Writes `text` to `name` in the folder and returns the file's path with its links resolved.
    @discardableResult
    func file(_ name: String, _ text: String = "let a = 1\n") throws -> String {
        let file = path + "/" + name
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: file, atomically: false, encoding: .utf8)
        return try #require(Disk.realPath(file))
    }

    func remove() { try? FileManager.default.removeItem(atPath: path) }
}

extension Diagnostic {
    /// A warning at column 5 of `line`.
    static func warning(_ path: String, _ line: Int, _ message: String) -> Diagnostic {
        Diagnostic(.warning, message, file: path, line: line, column: 5)
    }
}
