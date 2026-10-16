import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// What the warning record does when the build's log or the record itself cannot be used as it is. Shares the fakes and
/// helpers of `BuildWarningsTests`.
extension BuildWarningsTests {
    /// Makes xcresulttool report `results` after changing every log in the worktree's log folder, so the change lands
    /// between xcodebuild writing its log and xcd reading it.
    func changeLogs(in ctx: WorktreeContext, with change: @escaping @Sendable (URL) throws -> Void) {
        let folder = ctx.paths.logs
        fake.stub(["xcrun", "xcresulttool", "get"]) { _ in
            for name in try FileManager.default.contentsOfDirectory(atPath: folder) where name.hasSuffix(".log") {
                try change(URL(fileURLWithPath: folder + "/" + name))
            }
            return ProcessOutput(stdout: #"{"status":"succeeded","errors":[],"warnings":[]}"#)
        }
    }

    func recordFile(_ ctx: WorktreeContext) -> String { WarningRecord.file(scheme: "App", device: "mac", configuration: nil, in: ctx.paths) }

    func recordBytes(_ ctx: WorktreeContext) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: recordFile(ctx))) }

    /// One byte that is not valid UTF-8, in a run-script line, costs that line and nothing else.
    @Test func aLogWithABadByteIsStillRead() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        next(compiling: ["Login", "Session", "Other"], warnings: [("Login", 42)])
        _ = try await build(&ctx)
        try write("struct Login { let token = 2 }\n", to: "Login")                  // the warning is fixed
        next(compiling: ["Login"], warnings: [])
        changeLogs(in: ctx) { url in
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x72, 0xE9, 0x0A]))
        }
        let fixed = try await build(&ctx)
        #expect(fixed.warningLines.isEmpty && fixed.warningCount == 0 && fixed.unknownChangedFiles == nil)
        #expect(!String(decoding: try recordBytes(ctx), as: UTF8.self).contains("Login.swift\":[{"))
    }

    /// A log that cannot be read does not say which files the build compiled, so the record is not rewritten.
    @Test func aLogThatCannotBeReadLeavesTheRecordAsItWas() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        next(compiling: ["Login", "Session", "Other"], warnings: [("Login", 42)])
        _ = try await build(&ctx)
        let before = try recordBytes(ctx)
        changeLogs(in: ctx) { try FileManager.default.removeItem(at: $0) }
        let unread = try await build(&ctx)
        #expect(try recordBytes(ctx) == before)
        #expect(unread.succeeded && unread.notes == [WarningKeeper.unreadableLog] && unread.warningLines.isEmpty)
    }

    /// The record failing to save is not the build's failure, and the build's own warnings are still shown.
    @Test func aRecordThatCannotBeKeptStillShowsTheBuildsWarnings() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        let folder = (recordFile(ctx) as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: (folder as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "not a folder\n".write(toFile: folder, atomically: true, encoding: .utf8)
        next(compiling: ["Login", "Other"], warnings: [("Login", 42), ("Other", 3)])
        let report = try await build(&ctx)
        let note = try #require(report.notes.first { $0.hasPrefix("xcd could not keep this build's warnings: ") })
        #expect(report.succeeded && !note.contains("Error Domain="))
        #expect(report.warningLines == [line("Login", 42), "1 warning in the files you changed, 1 in other files (xcd build --warnings)"])
    }
}
