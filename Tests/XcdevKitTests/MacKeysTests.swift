import Testing
@testable import XcdevKit

@Suite struct MacKeysTests {
    @Test func charactersBecomeUnicodeKeysAndControlCharactersBecomeKeyCodes() {
        let keys = MacKeys.events(for: "a\u{8}\n\tÉ😀")
        #expect(keys.map(\.code) == [0, MacKeys.delete, MacKeys.returnKey, MacKeys.tab, 0, 0])
        #expect(keys.map(\.text) == ["a", nil, nil, nil, "É", "😀"])
        #expect(MacKeys.events(for: "\r\n").map(\.code) == [MacKeys.returnKey])      // "\r\n" is one Character in Swift
    }
}
