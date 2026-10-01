import Testing
@testable import SampleApp

@Test func passes() {
    #expect(1 + 1 == 2)
}

@Test func failsOnPurpose() {
    #expect(1 + 1 == 3, "failing on purpose")
}
