import Testing
@testable import XcdevKit

@Suite struct IdleThresholdTests {
    @Test func valuesReadAsWholeSeconds() {
        #expect(IdleThreshold.parse("off") == 0)
        #expect(IdleThreshold.parse("OFF") == 0)
        #expect(IdleThreshold.parse("30s") == 30)
        #expect(IdleThreshold.parse("5m") == 300)
        #expect(IdleThreshold.parse("1h") == 3600)
        #expect(IdleThreshold.parse("45") == 45)
        #expect(IdleThreshold.parse("500ms") == 1)
    }

    @Test func unreadableValuesAreRefused() {
        for text in ["0", "-5m", "200h", "soon", "", "10 minutes"] {
            #expect(IdleThreshold.parse(text) == nil, "\(text)")
        }
    }

    @Test func theFlagNamesItselfWhenUnreadable() throws {
        #expect(try IdleThreshold.option(nil) == nil)
        #expect(try IdleThreshold.option("off") == 0)
        let error = #expect(throws: XcdError.self) { try IdleThreshold.option("soon") }
        #expect(error?.code == .usage)
        #expect(error?.message == "--idle soon is not a duration")
        #expect(error?.next == "use a duration like 30s, 5m, or 1h, or off")
    }

    @Test func secondsReadBackAsText() {
        #expect(IdleThreshold.text(0) == "off")
        #expect(IdleThreshold.text(45) == "45s")
        #expect(IdleThreshold.text(600) == "10m")
        #expect(IdleThreshold.text(5400) == "90m")
        #expect(IdleThreshold.text(3600) == "1h")
    }
}
