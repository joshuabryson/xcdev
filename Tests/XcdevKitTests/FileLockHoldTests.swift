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
}
