import Foundation
import Testing
@testable import XcdevKit

@Suite struct RunnerSourceTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().path

    /// The embedded runner is generated; this fails until `scripts/embed-runner.sh` is re-run after an edit.
    @Test func theEmbeddedRunnerMatchesItsSources() throws {
        let project = Self.repo + "/Sources/XcdevKit/UIRunner/Project"
        let core = Self.repo + "/Sources/XcdevKit/UIRunner/Core"
        var expected: [String: String] = [:]
        for file in try FileManager.default.subpathsOfDirectory(atPath: project) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: project + "/" + file, isDirectory: &isDirectory), !isDirectory.boolValue,
                  !file.hasSuffix(".DS_Store") else { continue }
            expected[file] = try String(contentsOfFile: project + "/" + file, encoding: .utf8)
        }
        for file in try FileManager.default.contentsOfDirectory(atPath: core) where file.hasSuffix(".swift") {
            expected["XcdRunner/Core/" + file] = try String(contentsOfFile: core + "/" + file, encoding: .utf8)
        }
        let embedded = Dictionary(uniqueKeysWithValues: EmbeddedRunner.files.map { ($0.path, $0.contents + "\n") })
        #expect(embedded.keys.sorted() == expected.keys.sorted(), "run scripts/embed-runner.sh")
        for (path, contents) in expected {
            #expect(embedded[path] == contents, "run scripts/embed-runner.sh: \(path) changed")
        }
    }

    @Test func coreFilesImportOnlyFoundation() throws {
        let core = Self.repo + "/Sources/XcdevKit/UIRunner/Core"
        for file in try FileManager.default.contentsOfDirectory(atPath: core) where file.hasSuffix(".swift") {
            let imports = try String(contentsOfFile: core + "/" + file, encoding: .utf8).split(separator: "\n")
                .filter { $0.hasPrefix("import ") }
            #expect(imports == ["import Foundation"], "\(file) must import only Foundation: the runner compiles it too")
        }
    }

    @Test func writesEveryFileAndHashesTheSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd runner \(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try RunnerSource.write(to: dir)
        for needed in ["XcdRunner.xcodeproj/project.pbxproj", "XcdRunner.xcodeproj/xcshareddata/xcschemes/XcdRunner.xcscheme",
                       "XcdRunner.xctestplan", "XcdRunnerHost/HostApp.swift", "XcdRunner/XcdRunnerTests.swift",
                       "XcdRunner/XCUIDriver.swift", "XcdRunner/RunnerServer.swift", "XcdRunner/Core/RunnerEngine.swift"] {
            #expect(FileManager.default.fileExists(atPath: dir + "/" + needed), "\(needed) is missing")
        }
        #expect(RunnerSource.hash.count == 12 && RunnerSource.hash.allSatisfy(\.isHexDigit))
        #expect(RunnerSource.runnerBundleId == "dev.xcdev.XcdRunner.xctrunner")
        let plan = try String(contentsOfFile: dir + "/XcdRunner.xctestplan", encoding: .utf8)
        #expect(plan.contains(#""testTimeoutsEnabled" : false"#))
    }
}
