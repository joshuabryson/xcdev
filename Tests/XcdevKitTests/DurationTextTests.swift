import Testing
@testable import XcdevKit

@Suite struct DurationTextTests {
    @Test(arguments: [
        ("500ms", Duration.milliseconds(500)), ("30s", .seconds(30)), ("2m", .seconds(120)),
        ("1.5h", .seconds(5400)), ("45", .seconds(45)), (" 5M ", .seconds(300)),
    ])
    func parses(_ text: String, _ expected: Duration) {
        #expect(DurationText.parse(text) == expected)
    }

    @Test(arguments: ["", "0s", "-5s", "abc", "5x", "inf", "nan", "8d", "1000000h"])
    func rejects(_ text: String) {
        #expect(DurationText.parse(text) == nil)
    }

    @Test func formats() {
        #expect(DurationText.format(.milliseconds(400)) == "0.4s")
        #expect(DurationText.format(.milliseconds(12_440)) == "12.4s")
        #expect(DurationText.format(.seconds(125)) == "2m05s")
        #expect(DurationText.format(.seconds(3720)) == "1h02m")
        #expect(DurationText.seconds(.milliseconds(1500)) == 1.5)
    }
}
