import Testing
@testable import XcdevKit

@Suite struct SuggestTests {
    @Test func typoFindsKey() {
        #expect(Suggest.closest(to: "devics", in: ["devices", "presets", "project"]) == ["devices"])
    }

    @Test func prefixQueryRanksByDistance() {
        let got = Suggest.closest(to: "iphone 18", in: ["iPhone 18 Pro", "iPhone 18 Pro Max", "iPad Air"])
        #expect(got == ["iPhone 18 Pro", "iPhone 18 Pro Max"])
    }

    @Test func nothingCloseReturnsEmpty() {
        #expect(Suggest.closest(to: "zzzz", in: ["devices"]).isEmpty)
    }

    @Test func shellQuote() {
        #expect(Shell.quote("plain") == "plain")
        #expect(Shell.quote("/a b/c") == "'/a b/c'")
        #expect(Shell.quote("it's") == #"'it'\''s'"#)
    }
}
