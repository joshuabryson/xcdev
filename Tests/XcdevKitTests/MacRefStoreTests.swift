import Foundation
import Testing
@testable import XcdevKit

@Suite struct MacRefStoreTests {
    let paths = WorktreePaths(root: NSTemporaryDirectory() + "xcd-mac-refs-\(UUID().uuidString)")

    @Test func refsRoundTripAndAMissingFileIsAnEmptyTable() throws {
        defer { try? FileManager.default.removeItem(atPath: paths.root) }
        let file = MacRefStore.file(paths, device: "mac")
        #expect(MacRefStore.load(file) == MacRefs(refs: [:], lastRef: 0))
        let refs = MacRefs(refs: ["e3": RefSignature(role: "button", identifier: "go", label: "Go", path: [2, 0, 9, 1], source: .app)], lastRef: 3)
        try MacRefStore.save(refs, to: file)
        #expect(MacRefStore.load(file) == refs && file.hasSuffix("/.xcdev/ui-mac-mac.json"))
    }

    @Test func aLaunchForgetsEveryRef() throws {
        defer { try? FileManager.default.removeItem(atPath: paths.root) }
        try MacRefStore.save(MacRefs(refs: [:], lastRef: 2), to: MacRefStore.file(paths, device: "mac"))
        try MacRefStore.save(MacRefs(refs: [:], lastRef: 5), to: MacRefStore.file(paths, device: "studio"))
        MacRefStore.forgetAll(in: paths)
        #expect(MacRefStore.load(MacRefStore.file(paths, device: "mac")).lastRef == 0)
        #expect(MacRefStore.load(MacRefStore.file(paths, device: "studio")).lastRef == 0)
    }

    /// One level only (`.xcdev/DerivedData` can hold tens of thousands of files), and only the ref files.
    @Test func forgettingEveryRefLeavesEverythingElseInTheStateFolder() throws {
        defer { try? FileManager.default.removeItem(atPath: paths.root) }
        let nested = paths.stateDirectory + "/logs/ui-mac-deep.json"
        let other = paths.stateDirectory + "/worktree.json"
        try FileManager.default.createDirectory(atPath: paths.stateDirectory + "/logs", withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: nested))
        try Data("{}".utf8).write(to: URL(fileURLWithPath: other))
        try MacRefStore.save(MacRefs(refs: [:], lastRef: 2), to: MacRefStore.file(paths, device: "mac"))
        MacRefStore.forgetAll(in: paths)
        #expect(!FileManager.default.fileExists(atPath: MacRefStore.file(paths, device: "mac")))
        #expect(FileManager.default.fileExists(atPath: nested) && FileManager.default.fileExists(atPath: other))
        #expect(Disk.names(in: paths.stateDirectory) == ["logs", "worktree.json"] && Disk.names(in: paths.root + "/nothing").isEmpty)
    }
}
