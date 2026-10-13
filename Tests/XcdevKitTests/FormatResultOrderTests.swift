import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The result lists the files in their own order, whichever formatter finished first.
@Suite struct FormatResultOrderTests {
    /// Two at a time, over A.swift, C.swift and D.swift. A.swift's formatter answers only once D.swift's is asked,
    /// and D.swift is started only when C.swift is done and has freed its place: so C.swift is finished before
    /// A.swift for certain, with no clock. Results kept in the order they came in would begin with C.swift.
    @Test func aLaterFileThatFinishesFirstIsStillListedInItsPlace() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        try project.changeThreeFiles()
        let formatters = FakeFormatters()
        let service = project.service(formatters, atOnce: 2)
        let ctx = try await project.context()
        let lastStarted = DispatchSemaphore(value: 0)
        let waited = Shared<DispatchTimeoutResult?>(nil)
        project.fake.stub(["swiftformat", "stdin", "--stdin-path", project.root + "/Sources/App/A.swift"]) { _ in
            waited.set(lastStarted.wait(timeout: .now() + 10))                      // the limit only keeps a broken xcd from hanging the suite
            return ProcessOutput(exitCode: 0, stdout: FormatServiceTests.lineSeven, stderr: "")
        }
        project.fake.stub(["swiftformat", "stdin", "--stdin-path", project.root + "/Sources/App/D.swift"]) { _ in
            lastStarted.signal()
            return ProcessOutput(exitCode: 0, stdout: "let d = 1\n", stderr: "")
        }
        let report = try await service.format(FormatOptions(), in: ctx)

        #expect(waited.value == .success)                                            // D.swift was started while A.swift was under way
        #expect(formatters.runs.map(\.file) == [project.root + "/Sources/App/C.swift"])
        #expect(report.changed.map(\.file) == ["Sources/App/A.swift", "Sources/App/C.swift", "Sources/App/D.swift"])
        #expect(report.failure == nil && report.failed.isEmpty)
    }
}
