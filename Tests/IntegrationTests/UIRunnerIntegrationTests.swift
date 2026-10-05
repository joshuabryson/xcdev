import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"

@Suite(.enabled(if: enabled, "set XCD_INTEGRATION=1 to run (needs Xcode + an iOS simulator runtime)"), .serialized)
struct UIRunnerIntegrationTests {
    let runner = SystemProcessRunner()

    @Test(.timeLimit(.minutes(15))) func theEmbeddedRunnerBuildsWithNoSigningSetup() async throws {
        let dir = testsHome + "/runner-build-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try RunnerSource.write(to: dir + "/project")
        let out = try await runner.run(.xcrun(["xcodebuild", "build-for-testing", "-project", dir + "/project/" + RunnerSource.projectPath,
                                               "-scheme", RunnerSource.scheme, "-destination", "generic/platform=iOS Simulator",
                                               "-derivedDataPath", dir + "/DerivedData"], developerDir: nil, timeout: .seconds(840)))
        #expect(out.succeeded, "\(out.stdoutString.suffix(3000))\n\(out.stderrString.suffix(2000))")
        let products = dir + "/DerivedData/Build/Products"
        let runs = try FileManager.default.contentsOfDirectory(atPath: products).filter { $0.hasSuffix(".xctestrun") }
        #expect(runs.count == 1)
    }
}
