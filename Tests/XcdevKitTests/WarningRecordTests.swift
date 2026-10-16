import Foundation
import Testing
@testable import XcdevKit

/// The warnings xcd keeps from one build to the next, because xcodebuild reports a file's warnings only in a build
/// that compiles it. Real files in a temporary folder.
@Suite struct WarningRecordTests {
    let folder = WarningFolder()

    @Test func aCompiledFilesEntryIsReplacedWithThisBuildsWarningsOrNone() throws {
        defer { folder.remove() }
        let a = try folder.file("A.swift"), b = try folder.file("B.swift")
        let first = WarningRecord().updated(compiled: [a, b], warnings: [Diagnostic.warning(a, 1, "unused"), Diagnostic.warning(a, 2, "deprecated")])
        #expect(first.files[a]?.warnings == [RecordedWarning(line: 1, column: 5, message: "unused"),
                                             RecordedWarning(line: 2, column: 5, message: "deprecated")])
        #expect(first.files[b]?.warnings == [] && first.files[a]?.stamp == FileStamp.of(a))
        // A build that compiles nothing leaves every entry; one that compiles A again replaces A's.
        #expect(first.updated(compiled: [], warnings: []) == first)
        let fixed = first.updated(compiled: [a], warnings: [Diagnostic.warning(a, 2, "deprecated")])
        #expect(fixed.files[a]?.warnings == [RecordedWarning(line: 2, column: 5, message: "deprecated")] && fixed.files[b] == first.files[b])
    }

    /// A warning in a file the build did not compile, such as one from emitting the module, is added to its entry.
    @Test func aWarningInAFileThatWasNotCompiledIsAddedToItsEntry() throws {
        defer { folder.remove() }
        let a = try folder.file("A.swift")
        let first = WarningRecord().updated(compiled: [a], warnings: [Diagnostic.warning(a, 1, "unused")])
        let emitted = first.updated(compiled: [], warnings: [Diagnostic.warning(a, 9, "from emitting the module"), Diagnostic.warning(a, 1, "unused")])
        #expect(emitted.files[a]?.warnings.map(\.message) == ["unused", "from emitting the module"])
        // A file the record has no entry for gets one.
        let c = try folder.file("C.swift")
        #expect(WarningRecord().updated(compiled: [], warnings: [Diagnostic.warning(c, 3, "x")]).files[c]?.warnings.count == 1)
    }

    /// A file that changed since its entry was made has an entry that says nothing about it now, so a warning added
    /// for it replaces the entry rather than joining it.
    @Test func aWarningForAFileThatChangedSinceItsEntryReplacesTheEntry() throws {
        defer { folder.remove() }
        let a = try folder.file("A.swift")
        let first = WarningRecord().updated(compiled: [a], warnings: [Diagnostic.warning(a, 1, "unused")])
        let changed = try folder.file("A.swift", "let a = 2 // changed\n")
        #expect(FileStamp.of(changed) != first.files[a]?.stamp)
        let after = first.updated(compiled: [], warnings: [Diagnostic.warning(changed, 2, "new")])
        #expect(after.files[a]?.warnings == [RecordedWarning(line: 2, column: 5, message: "new")])
        #expect(after.files[a]?.stamp == FileStamp.of(a))
    }

    /// A header's warnings come through the files that include it, and an asset catalog's from a step the log does
    /// not name, so neither can be known to be gone: they are this build's only.
    @Test func onlyTheKindsOfFileTheLogNamesAreKept() throws {
        defer { folder.remove() }
        let header = try folder.file("Obj.h"), catalog = try folder.file("Assets.xcassets/Contents.json")
        let record = WarningRecord().updated(compiled: [], warnings: [Diagnostic.warning(header, 1, "h"), Diagnostic.warning(catalog, 1, "c"),
                                                                      Diagnostic(.warning, "no file")])
        #expect(record.files.isEmpty)
    }

    @Test func aFileThatIsGoneOrWhoseNameChangedCaseIsDropped() throws {
        defer { folder.remove() }
        let login = try folder.file("Login.swift"), gone = try folder.file("Gone.swift")
        let record = WarningRecord().updated(compiled: [login, gone], warnings: [Diagnostic.warning(login, 1, "unused"), Diagnostic.warning(gone, 1, "unused")])
        try FileManager.default.removeItem(atPath: gone)
        try FileManager.default.moveItem(atPath: login, toPath: folder.path + "/tmp.swift")
        try FileManager.default.moveItem(atPath: folder.path + "/tmp.swift", toPath: folder.path + "/login.swift")
        #expect(FileManager.default.fileExists(atPath: login))                         // the disk ignores case
        #expect(record.updated(compiled: [], warnings: []).files.isEmpty)
    }

    /// Paths reach the record as the log and the result bundle spell them: `/tmp/…` and `/private/tmp/…` are one file.
    @Test func aFileIsKeptByItsPathWithLinksResolved() throws {
        defer { folder.remove() }
        let a = try folder.file("A.swift")
        let linked = folder.path + "/Linked"
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: folder.path)
        let record = WarningRecord().updated(compiled: [linked + "/A.swift"], warnings: [Diagnostic.warning(linked + "/A.swift", 1, "unused")])
        #expect(Array(record.files.keys) == [a])
    }

    /// The stamp tells a file that changed within the same second and kept its size.
    @Test func aStampHasTheModificationTimeToTheNanosecond() throws {
        defer { folder.remove() }
        let a = try folder.file("A.swift")
        let base = Date(timeIntervalSince1970: 1_790_040_000.25)
        try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: a)
        let before = try #require(FileStamp.of(a))
        try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(0.001)], ofItemAtPath: a)
        #expect(FileStamp.of(a) != before && FileStamp.of(a)?.seconds == before.seconds && FileStamp.of(a)?.size == before.size)
        #expect(FileStamp.of(folder.path + "/none.swift") == nil)
    }

    @Test func aRecordIsKeptPerSchemeDeviceAndConfiguration() throws {
        let paths = WorktreePaths(root: "/w")
        #expect(WarningRecord.file(scheme: "App", device: "iphone", configuration: nil, in: paths) == "/w/.xcdev/warnings/App~iphone~default.json")
        #expect(WarningRecord.file(scheme: "My/App", device: "mac", configuration: "Release", in: paths)
                == "/w/.xcdev/warnings/My_App~mac~Release.json")
    }

    /// Two builds of the same worktree at once each change the record under its lock, so neither loses the other's.
    @Test func updatesUnderTheLockKeepEachOther() async throws {
        defer { folder.remove() }
        let a = try folder.file("A.swift"), b = try folder.file("B.swift")
        let record = folder.path + "/warnings/App~iphone~default.json"
        async let first = WarningRecord.update(at: record) { $0.updated(compiled: [a], warnings: [Diagnostic.warning(a, 1, "a")]) }
        async let second = WarningRecord.update(at: record) { $0.updated(compiled: [b], warnings: [Diagnostic.warning(b, 1, "b")]) }
        let wasNew = try await [first.isNew, second.isNew]
        #expect(wasNew.sorted { !$0 && $1 } == [false, true])                         // one of them made it
        #expect(WarningRecord.load(record)?.files.keys.sorted() == [a, b].sorted())
    }

    @Test func aRecordThatCannotBeReadStartsOver() async throws {
        defer { folder.remove() }
        let record = try folder.file("warnings/App~iphone~default.json", "{nope")
        #expect(WarningRecord.load(record) == nil)
        let (_, isNew) = try await WarningRecord.update(at: record) { $0 }
        #expect(isNew)
    }
}
