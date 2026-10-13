import Foundation
import Testing
@testable import XcdevKit

/// A folder of xcd's own outside every worktree. `LintFolderTests` covers what an
/// interrupt does while a write is under way; these cover what the folder is called and what it says.
@Suite struct ScratchFolderTests {
    @Test func theFolderIsNamedForItsPurposeAndRemoveDeletesIt() throws {
        let folder = try ScratchFolder.create(for: "format")
        #expect((folder.root as NSString).lastPathComponent.hasPrefix("xcd-format-"))
        #expect(folder.root.hasPrefix((NSTemporaryDirectory() as NSString).standardizingPath) || folder.root.hasPrefix(NSTemporaryDirectory()))
        try folder.write(Data("let a = 1\n".utf8), to: "in/A.swift")
        #expect(try String(contentsOfFile: folder.root + "/in/A.swift", encoding: .utf8) == "let a = 1\n")
        folder.remove()
        #expect(!FileManager.default.fileExists(atPath: folder.root))
    }

    @Test func afterAnInterruptNothingIsWrittenAndTheErrorNamesTheFolder() throws {
        let interrupts = LintFolderTests.quietInterrupts()
        let folder = try ScratchFolder.create(for: "format", removedBy: interrupts)
        #expect(interrupts.handle(SIGINT) == 130)
        #expect(!FileManager.default.fileExists(atPath: folder.root))                // the handler removed it
        let error = #expect(throws: XcdError.self) { try folder.write(Data("x".utf8), to: "A.swift") }
        #expect(error?.message == "xcd was interrupted, so nothing more was written to its format folder")
        #expect(!FileManager.default.fileExists(atPath: folder.root))                // and the write did not bring it back
    }
}
