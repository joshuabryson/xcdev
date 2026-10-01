import Testing
@testable import XcdevKit

@Test func versionIsSemantic() {
    #expect(XcdevVersion.current.split(separator: ".").count == 3)
}
