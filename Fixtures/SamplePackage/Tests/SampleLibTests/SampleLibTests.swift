import Testing
@testable import SampleLib

@Test func greetingIncludesName() {
    #expect(SampleLib.greeting(for: "xcdev") == "Hello, xcdev!")
}
