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

    @Test func summaryAloneStillListsFailures() throws {
        let results = try TestResults.parse(summary: data("test-results-summary-failed.json"), tests: nil)
        #expect(results.failures.map(\.test) == ["SampleAppTests/failsOnPurpose()"])
        #expect(results.failures[0].file == nil)
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
