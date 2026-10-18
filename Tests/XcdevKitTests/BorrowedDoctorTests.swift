import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Doctor in a checkout whose config is borrowed from the main checkout edits nothing there.
@Suite struct BorrowedDoctorTests {
    let quality = QualityChecksTests()

    @Test func aSectionTheBorrowedConfigLacksIsLeftToTheUser() async throws {
        let project = try quality.setup()
        defer { project.remove() }
        let path = try BorrowedConfigTests.worktreeWithoutConfig(project)
        try project.write("included:\n  - App\n", to: ".swiftlint.yml", in: path)
        let main = project.root + "/.xcdev.yml"

        let notes = Notes()
        let report = await Notes.$current.withValue(notes) {
            await quality.doctor(project).run(fix: true, checks: [QualitySetupCheck()], from: path)
        }
        #expect(notes.all.count == 1)
        #expect(notes.all.first?.hasPrefix("this branch has no .xcdev.yml, so xcd uses the main checkout's (\(main))") == true)
        #expect(report.problems == [
            DoctorProblem(check: "quality-setup", message: "the main checkout's " + QualityChecksTests.problem,
                          next: "ask the user whether to add a `lint:` section to the main checkout's .xcdev.yml (\(main))",
                          subject: main).inProject(project.root)])
        #expect(try quality.config(project) == QualityChecksTests.base)
        #expect(!FileManager.default.fileExists(atPath: path + "/.xcdev.yml"))
    }

    @Test func aRecordingInABorrowedCheckoutHasTheMainCheckoutsLimit() async throws {
        let project = try quality.setup(QualityChecksTests.base + "ui:\n  record:\n    maxDuration: 30m\n")
        defer { project.remove() }
        let path = try BorrowedConfigTests.worktreeWithoutConfig(project)
        _ = try await BorrowedConfigTests().service(project).open(from: path)
        let registry = try Registry(paths: GlobalPaths(base: project.home)).entries()
        let entry = try #require(registry.first { $0.path.hasSuffix("/elsewhere/old") })
        #expect(RecordingsCheck().limit(entry) == .seconds(1800))
    }
}
