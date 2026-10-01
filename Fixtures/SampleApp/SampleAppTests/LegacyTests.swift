import XCTest
@testable import SampleApp

final class LegacyTests: XCTestCase {
    func testPasses() {
        XCTAssertTrue(true)
    }

    func testSkipped() throws {
        throw XCTSkip("skipped on purpose")
    }
}
