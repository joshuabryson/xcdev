import Foundation
import Testing
@testable import XcdevKit

@Suite struct ResultParsingTests {
    func data(_ name: String) -> Data { Data(Fixture.string(name).utf8) }

    @Test func failedBuildHasOneBasedLocationsAndDecodedPaths() throws {
        let results = try BuildResults.parse(data("build-results-failed.json"))
        #expect(!results.succeeded)
        #expect(results.errors.map(\.text) == [
            "/Users/dev/My Apps/SampleApp/SampleApp/BrokenAuth.swift:3:16: error: Cannot find 'authModel' in scope",
            "/Users/dev/My Apps/SampleApp/SampleApp/BrokenMath.swift:2:23: error: Cannot convert value of type 'String' to specified type 'Int'",
        ])
        #expect(results.warningCount == 0)
    }

    @Test func succeededBuildCountsWarnings() throws {
        let results = try BuildResults.parse(data("build-results-succeeded.json"))
        #expect(results.succeeded && results.errors.isEmpty)
        #expect(results.warningCount == 1)
        #expect(results.warnings.first?.text.hasPrefix("/Users/dev/My Apps/SampleApp/SampleApp/Warnings.swift:2:9: warning: Initialization of immutable value 'unusedValue' was never used") == true)
    }

    @Test func issueWithoutSourceURLHasNoLocation() throws {
        let json = #"{"status":"failed","errorCount":1,"warningCount":0,"errors":[{"issueType":"Error","message":"Signing requires a development team."}],"warnings":[]}"#
        let results = try BuildResults.parse(Data(json.utf8))
        #expect(results.errors.map(\.text) == ["error: Signing requires a development team."])
    }

    @Test func unreadableBuildResultsThrow() {
        #expect(throws: XcdError.self) { try BuildResults.parse(Data("{".utf8)) }
    }

    @Test func failedTestsCarryIdentifierFileAndLine() throws {
        let results = try TestResults.parse(summary: data("test-results-summary-failed.json"),
                                            tests: data("test-results-tests-failed.json"))
        #expect(results.counts == TestCounts(total: 4, passed: 2, failed: 1, skipped: 1, expectedFailures: 0))
        #expect(results.failures == [TestFailure(
            test: "SampleAppTests/failsOnPurpose()",
            message: "Expectation failed: 1 + 1 == 3\n1 + 1 → 2: failing on purpose",
            file: "/Users/dev/My Apps/SampleApp/SampleAppTests/SampleAppTests.swift", line: 9)])
        #expect(results.failures[0].diagnostic.text == """
        /Users/dev/My Apps/SampleApp/SampleAppTests/SampleAppTests.swift:9: error: SampleAppTests/failsOnPurpose(): Expectation failed: 1 + 1 == 3
            1 + 1 → 2: failing on purpose
        """)
    }

    /// Xcode 26.2 gives a failure no `sourceLocation` and starts its text with the file's name and the line instead.
    @Test func aFailureWithoutALocationTakesItFromTheStartOfItsText() throws {
        func tree(_ message: String, location: String = "") -> Data {
            let failure = #"{"name":"\#(message)","nodeType":"Failure Message"\#(location)}"#
            let testCase = #"{"name":"direct()","nodeType":"Test Case","result":"Failed","#
                + #""nodeIdentifierURL":"test://com.apple.xcode/SampleApp/SampleAppTests/direct()","children":[\#(failure)]}"#
            return Data(#"{"testNodes":[{"name":"P","nodeType":"Test Plan","children":[\#(testCase)]}]}"#.utf8)
        }
        func failure(_ tree: Data) throws -> TestFailure {
            try #require(TestResults.parse(summary: data("test-results-summary-nested.json"), tests: tree).failures.first)
        }
        #expect(try failure(tree("SampleAppTests.swift:9: Expectation failed: (1 + 1 → 2) == 3: failing on purpose")) == TestFailure(
            test: "SampleAppTests/direct()", message: "Expectation failed: (1 + 1 → 2) == 3: failing on purpose",
            file: "SampleAppTests.swift", line: 9))
        #expect(try failure(tree("My Tests.swift:12: XCTAssertEqual failed")).file == "My Tests.swift")
        // A text that only looks like it starts with a location, and a failure that has one, are left as they are.
        for text in ["Expectation failed: a:1: b", "Value 3:12: off", "x.swift:+9: y", "x.swift:9:no space"] {
            #expect(try failure(tree(text)) == TestFailure(test: "SampleAppTests/direct()", message: text, file: nil, line: nil))
        }
        let located = try failure(tree("Other.swift:3: x", location: #","sourceLocation":{"filePath":"/a/A.swift","lineNumber":7}"#))
        #expect(located.message == "Other.swift:3: x" && located.file == "/a/A.swift" && located.line == 7)
    }

    /// The bare name becomes the file's path in the worktree when exactly one file there has that name.
    @Test func aBareFileNameIsPlacedWhenOnlyOneFileHasIt() {
        func results(_ files: [String?]) -> TestResults {
            TestResults(counts: TestCounts(total: 1, passed: 0, failed: 1, skipped: 0, expectedFailures: 0),
                        failures: files.map { TestFailure(test: "T/t()", message: "m", file: $0, line: 1) })
        }
        let known = ["SampleAppTests/SampleAppTests.swift", "SampleApp/App.swift", "A/Twice.swift", "B/Twice.swift", "Top.swift"]
        let placed = results(["SampleAppTests.swift", "Twice.swift", "Missing.swift", "/abs/App.swift", "Top.swift", nil])
            .placing(known, under: "/w")
        #expect(placed.failures.map(\.file) == ["/w/SampleAppTests/SampleAppTests.swift", "Twice.swift", "Missing.swift",
                                                "/abs/App.swift", "/w/Top.swift", nil])
        #expect(results(["/abs/App.swift", nil]).needsPlacing == false && results(["Top.swift"]).needsPlacing)
    }

    @Test func summaryAloneStillListsFailures() throws {
        let results = try TestResults.parse(summary: data("test-results-summary-failed.json"), tests: nil)
        #expect(results.failures.map(\.test) == ["SampleAppTests/failsOnPurpose()"])
        #expect(results.failures[0].file == nil)
    }

    @Test func nestedFailuresAreKeptAlongsideDirectOnes() throws {
        let results = try TestResults.parse(summary: data("test-results-summary-nested.json"),
                                            tests: data("test-results-tests-nested.json"))
        #expect(results.failures.map(\.test) == ["SampleAppTests/direct()", "SampleAppTests/parameterized(value:)"])
        #expect(results.failures[1].file == "/Users/dev/My Apps/SampleApp/SampleAppTests/A.swift" && results.failures[1].line == 12)
    }

    @Test func summaryFailureMissingFromTheTreeIsStillListed() throws {
        let tree = #"{"testNodes":[{"name":"P","nodeType":"Test Plan","children":[{"name":"direct()","nodeType":"Test Case","result":"Failed","nodeIdentifierURL":"test://com.apple.xcode/SampleApp/SampleAppTests/direct()","children":[{"name":"x","nodeType":"Failure Message","sourceLocation":{"filePath":"/a.swift","lineNumber":1}}]}]}]}"#
        let results = try TestResults.parse(summary: data("test-results-summary-nested.json"), tests: Data(tree.utf8))
        #expect(results.failures.map(\.test) == ["SampleAppTests/direct()", "SampleAppTests/parameterized(value:)"])
        #expect(results.failures[1].file == nil)
    }

    @Test func filterThatMatchedNothingHasZeroTests() throws {
        let results = try TestResults.parse(summary: data("test-results-summary-empty.json"), tests: nil)
        #expect(results.counts.total == 0 && results.failures.isEmpty)
    }

    @Test func testIdentifiers() {
        #expect(TestResults.testIdentifier(fromURL: "test://com.apple.xcode/SampleApp/SampleAppTests/LegacyTests/testPasses")
                == "SampleAppTests/LegacyTests/testPasses")
        #expect(TestResults.testIdentifier(fromURL: "test://com.apple.xcode/SamplePackage/SampleLibTests/greetingIncludesName()")
                == "SampleLibTests/greetingIncludesName()")
    }

    @Test func buildSettingsPickTheAppNotTheTestBundle() throws {
        let app = try #require(try BuildSettings.app(from: data("build-settings.json"), preferredTarget: nil))
        #expect(app == AppProduct(path: "/Users/dev/My Apps/dd/Build/Products/Debug-iphonesimulator/SampleApp.app",
                                  bundleId: "dev.xcdev.SampleApp", executableName: "SampleApp", platform: "iphonesimulator"))
    }

    @Test func buildSettingsWithoutAnAppIsNil() throws {
        let json = #"[{"action":"build","target":"SampleLib","buildSettings":{"PRODUCT_TYPE":"com.apple.product-type.library.static","PLATFORM_NAME":"macosx"}}]"#
        #expect(try BuildSettings.app(from: Data(json.utf8), preferredTarget: "SamplePackage") == nil)
    }
}
