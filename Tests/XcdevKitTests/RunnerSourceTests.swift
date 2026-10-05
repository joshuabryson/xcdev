import Foundation
import Testing
@testable import XcdevKit

@Suite struct RunnerSourceTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().path

    /// The runner sources on disk, as the embed script lists them.
    static func sourcesOnDisk() throws -> [String: Data] {
        let project = repo + "/Sources/XcdevKit/UIRunner/Project"
        let core = repo + "/Sources/XcdevKit/UIRunner/Core"
        var expected: [String: Data] = [:]
        for file in try FileManager.default.subpathsOfDirectory(atPath: project) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: project + "/" + file, isDirectory: &isDirectory), !isDirectory.boolValue,
                  !file.hasSuffix(".DS_Store"), !file.contains("/xcuserdata/"), !file.contains("/project.xcworkspace/") else { continue }
            expected[file] = try Data(contentsOf: URL(fileURLWithPath: project + "/" + file))
        }
        for file in try FileManager.default.contentsOfDirectory(atPath: core) where file.hasSuffix(".swift") {
            expected["XcdRunner/Core/" + file] = try Data(contentsOf: URL(fileURLWithPath: core + "/" + file))
        }
        return expected
    }

    /// The embedded runner is generated; this fails until `scripts/embed-runner.sh` is re-run after an edit.
    @Test func theEmbeddedRunnerMatchesItsSources() throws {
        let expected = try Self.sourcesOnDisk()
        let embedded = Dictionary(uniqueKeysWithValues: try RunnerSource.embedded.get().map { ($0.path, $0.contents) })
        #expect(embedded.keys.sorted() == expected.keys.sorted(), "run scripts/embed-runner.sh")
        for (path, contents) in expected {
            #expect(embedded[path] == contents, "run scripts/embed-runner.sh: \(path) changed")
        }
    }

    @Test func aCorruptedArchiveIsAnInternalErrorNotATrap() {
        let valid = EmbeddedRunner.archive
        let truncated = String(valid.prefix(valid.count / 2))
        for broken in ["", "not base64 !!!", "AAAA", "H4sIAAAAAAAA", truncated] {
            #expect(throws: XcdError.self) { try RunnerSource.decode(broken) }
        }
        #expect(throws: XcdError(.internalError, "the embedded UI runner source is unreadable",
                                 next: "this is a bug in xcd; please report it")) { try RunnerSource.decode("AAAA") }
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
        for (path, contents) in try Self.sourcesOnDisk() {
            #expect(try Data(contentsOf: URL(fileURLWithPath: dir + "/" + path)) == contents, "\(path) differs from its source")
        }
        #expect(RunnerSource.hash.count == 12 && RunnerSource.hash.allSatisfy(\.isHexDigit))
        #expect(RunnerSource.runnerBundleId == "dev.xcdev.XcdRunner.xctrunner")
        let plan = try String(contentsOfFile: dir + "/XcdRunner.xctestplan", encoding: .utf8)
        #expect(plan.contains(#""testTimeoutsEnabled" : false"#))
    }

    private func container(_ parts: [Data]) -> Data { parts.reduce(Data(), +) }
    private func entry(_ path: String, count: String, bytes: Data) -> Data {
        Data(path.utf8) + Data([0]) + Data(count.utf8) + Data([0]) + bytes
    }

    @Test func aWellFormedContainerParsesToItsFiles() throws {
        let data = container([entry("a/b.txt", count: "3", bytes: Data("abc".utf8)), entry("c", count: "0", bytes: Data())])
        let files = try RunnerSource.parse(data)
        #expect(files.map(\.path) == ["a/b.txt", "c"])
        #expect(files.map(\.contents) == [Data("abc".utf8), Data()])
    }

    @Test func aBadContainerIsAnInternalErrorNotATrap() {
        let bad: [Data] = [
            entry("a", count: "x", bytes: Data("abc".utf8)),
            entry("a", count: "-1", bytes: Data("abc".utf8)),
            entry("a", count: "9", bytes: Data("abc".utf8)),
            Data("a".utf8) + Data([0]) + Data("3".utf8),
            Data("a".utf8),
            entry("../evil", count: "1", bytes: Data("x".utf8)),
            entry("a/../b", count: "1", bytes: Data("x".utf8)),
            entry("/abs", count: "1", bytes: Data("x".utf8)),
            entry("", count: "1", bytes: Data("x".utf8)),
        ]
        for data in bad {
            #expect(throws: XcdError.self) { try RunnerSource.parse(data) }
        }
    }
}
