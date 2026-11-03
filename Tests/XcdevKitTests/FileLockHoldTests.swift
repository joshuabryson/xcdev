import Foundation
import Testing
@testable import XcdevKit

@Suite struct FileLockHoldTests {
    @Test func holdsAreSharedAndKeepAnExclusiveTryOut() async throws {
        let path = NSTemporaryDirectory() + "hold-\(UUID().uuidString)/lease.lock"
        let first = try await FileLock.hold(at: path)
        let second = try await FileLock.hold(at: path)
        #expect(FileLock.isHeld(at: path))
        #expect(try await FileLock.withLockIfFree(at: path) { true } == nil)
        FileLock.release(first)
        #expect(FileLock.isHeld(at: path))           // a lock belongs to its open file description
        FileLock.release(second)
        #expect(!FileLock.isHeld(at: path))
    }

    /// The lock file's folder, made read-only as a `sudo xcd` leaves it for this user: root owns it.
    static func readOnly(_ folder: String) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
    }

    static func cleanUp(_ base: String, readOnly folder: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
        try? FileManager.default.removeItem(atPath: base)
    }

    static func next(_ folder: String) -> String {
        "check that \(folder) and its files belong to you and are writable (a `sudo xcd` can leave them owned by root): "
            + "`ls -l \(Shell.quote(folder))`"
    }

    @Test func aLockFileThatCannotBeMadeNamesItsFolder() async throws {
        let base = NSTemporaryDirectory() + "hold-\(UUID().uuidString)", folder = base + "/devices/U1"
        try Self.readOnly(folder)
        defer { Self.cleanUp(base, readOnly: folder) }
        let error = await #expect(throws: XcdError.self) { _ = try await FileLock.hold(at: folder + "/lease.lock") }
        #expect(error?.code == .internalError)
        #expect(error?.message.contains(folder + "/lease.lock") == true)
        #expect(error?.next == Self.next(folder))
    }

    /// The folder `devices/` itself is read-only, so the clone's folder cannot be made: `next:` names the folder that is
    /// there, which is the one to look at.
    @Test func aLockFolderThatCannotBeMadeNamesTheFolderAboveIt() async throws {
        let base = NSTemporaryDirectory() + "hold space-\(UUID().uuidString)", devices = base + "/devices"
        try Self.readOnly(devices)
        defer { Self.cleanUp(base, readOnly: devices) }
        let error = await #expect(throws: XcdError.self) { _ = try await FileLock.hold(at: devices + "/U1/lease.lock") }
        #expect(error?.code == .internalError)
        #expect(error?.message.contains(devices + "/U1/lease.lock") == true)
        #expect(error?.next == Self.next(devices))
        #expect(error?.next?.hasSuffix("`ls -l '\(devices)'`") == true)
    }
}
