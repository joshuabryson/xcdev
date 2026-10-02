import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"

/// What `xcd init` reads from the project files matches what real xcodebuild reports for the same project. Runs
/// xcodebuild -list and -showBuildSettings on a copy of Fixtures/SampleApp; creates no simulators.
@Suite(.enabled(if: enabled, "set XCD_INTEGRATION=1 to run (needs Xcode)"))
struct ProjectFilesParityTests {
    @Test func projectFilesAgreeWithXcodebuildOnSampleApp() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("xcd parity \(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let root = base + "/SampleApp"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: repoRoot + "/Fixtures/SampleApp", toPath: root)
        let runner = SystemProcessRunner()
        func detector(_ scratch: String) -> ProjectDetector {
            ProjectDetector(runner: runner, developerDir: nil, scratch: base + "/" + scratch, xcodeDerivedData: base + "/no DerivedData")
        }

        let files = try await detector("files").detect(root: root, container: "SampleApp.xcodeproj")
        #expect(files.notes.isEmpty, "the project files weren't enough: \(files.notes)")

        let resolved = try ProjectContainer.resolve(config: XcdevConfig(version: 1, project: "SampleApp.xcodeproj"), worktreeRoot: root)
        let xcodebuild = try await detector("xcodebuild").detectWithXcodebuild(resolved, root: root, container: "SampleApp.xcodeproj",
                                                                                names: ["SampleApp"], notes: [])
        #expect(xcodebuild.notes.isEmpty, "\(xcodebuild.notes)")
        #expect(files.schemes == xcodebuild.schemes)
        #expect(files.appSchemes == xcodebuild.appSchemes)
        #expect(files.testSchemes == xcodebuild.testSchemes)
        #expect(files.platforms == xcodebuild.platforms)
        #expect(files.deviceFamilies == xcodebuild.deviceFamilies)
    }
}
