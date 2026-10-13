import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Finding the two formatters, and their config files.
@Suite struct FormatterLocatorTests {
    let runner = FakeProcessRunner()

    func locator(path: String) -> FormatterLocator {
        FormatterLocator(tools: ToolLocator(environment: ["PATH": path], extraFolders: []), runner: runner)
    }

    @Test func swiftFormatIsLookedForAsTheLinterIs() async throws {
        let root = try ToolLocatorTests().tree(["bin/swiftformat", "worktree/tools/swiftformat"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let locator = locator(path: root + "/bin")
        #expect(await locator.locate(.swiftFormat, path: nil, worktreeRoot: root + "/worktree", developerDir: nil) == root + "/bin/swiftformat")
        #expect(await locator.locate(.swiftFormat, path: "tools/swiftformat", worktreeRoot: root + "/worktree", developerDir: nil)
                == root + "/worktree/tools/swiftformat")
        #expect(await self.locator(path: root + "/none").locate(.swiftFormat, path: nil, worktreeRoot: root, developerDir: nil) == nil)
        #expect(runner.calls.isEmpty)
    }

    @Test func applesFormatterIsTheOneInsideTheWorktreesXcode() async throws {
        let root = try ToolLocatorTests().tree(["Xcode.app/Contents/Developer/Toolchains/usr/bin/swift-format", "bin/swift-format"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let inside = root + "/Xcode.app/Contents/Developer/Toolchains/usr/bin/swift-format"
        runner.stub(["xcrun", "--find", "swift-format"], stdout: inside + "\n")
        let locator = locator(path: root + "/bin")                                // one in PATH is not asked for
        #expect(await locator.locate(.appleSwiftFormat, path: nil, worktreeRoot: root, developerDir: root + "/Xcode.app/Contents/Developer") == inside)
        #expect(runner.calls.last?.environment == ["DEVELOPER_DIR": root + "/Xcode.app/Contents/Developer"])
        #expect(await locator.locate(.appleSwiftFormat, path: nil, worktreeRoot: root, developerDir: nil) == inside)
        #expect(runner.calls.last?.environment == [:])
        #expect(runner.calls.map(\.commandLine) == ["xcrun --find swift-format", "xcrun --find swift-format"])
    }

    @Test func anXcodeWithoutOneHasNoFormatter() async throws {
        let root = try ToolLocatorTests().tree(["bin/swift-format"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        runner.stub(["xcrun"], exitCode: 72, stderr: "xcrun: error: unable to find utility \"swift-format\", not a developer tool or in PATH\n")
        #expect(await locator(path: root + "/bin").locate(.appleSwiftFormat, path: nil, worktreeRoot: root, developerDir: nil) == nil)
        runner.stub(["xcrun"], stdout: root + "/gone/swift-format\n")              // an answer that names no file
        #expect(await locator(path: root + "/bin").locate(.appleSwiftFormat, path: nil, worktreeRoot: root, developerDir: nil) == nil)
    }

    @Test func aConfiguredPathIsUsedForApplesFormatterTooAndXcodeIsNotAsked() async throws {
        let root = try ToolLocatorTests().tree(["tools/swift-format"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(await locator(path: "").locate(.appleSwiftFormat, path: "tools/swift-format", worktreeRoot: root, developerDir: nil)
                == root + "/tools/swift-format")
        #expect(await locator(path: "").locate(.appleSwiftFormat, path: "tools/missing", worktreeRoot: root, developerDir: nil) == nil)
        #expect(runner.calls.isEmpty)
    }

    @Test func aMissingFormatterSaysHowToGetItOrWhatElseToChoose() {
        let nick = FormatterLocator.missing(.swiftFormat, path: nil)
        #expect(nick.code == .toolMissing && nick.code.exitCode == 3)
        #expect(nick.message == "swiftformat is not installed: it is not in PATH, /opt/homebrew/bin, or /usr/local/bin")
        #expect(nick.next == "brew install swiftformat, or set format.path in .xcdev.local.yml")
        let apple = FormatterLocator.missing(.appleSwiftFormat, path: nil)
        #expect(apple.code == .toolMissing && apple.message == "the selected Xcode has no swift-format")
        #expect(apple.next == "set format.tool to swiftformat or none in .xcdev.yml, or set format.path in .xcdev.local.yml to a swift-format outside Xcode")
        let wrongPath = FormatterLocator.missing(.appleSwiftFormat, path: "tools/swift-format")
        #expect(wrongPath.message == "format.path names 'tools/swift-format', which is not a file that can be run")
        #expect(wrongPath.next == "fix format.path in .xcdev.yml or .xcdev.local.yml, or remove it to have xcd use the swift-format inside Xcode")
        #expect(FormatterLocator.missing(.swiftFormat, path: "x").next == "fix format.path in .xcdev.yml or .xcdev.local.yml, or remove it to have xcd look in PATH")
    }

    @Test func theFormattersAProjectHasConfigFilesFor() throws {
        let root = try ToolLocatorTests().tree(["elsewhere/.swiftformat"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(QualityDetection.formatters(configuredIn: root).isEmpty)
        try "{}\n".write(toFile: root + "/.swift-format", atomically: true, encoding: .utf8)
        #expect(QualityDetection.formatters(configuredIn: root) == [.appleSwiftFormat])
        try FileManager.default.createSymbolicLink(atPath: root + "/.swiftformat", withDestinationPath: root + "/elsewhere/.swiftformat")
        #expect(QualityDetection.formatters(configuredIn: root) == [.appleSwiftFormat, .swiftFormat])
        try FileManager.default.removeItem(atPath: root + "/.swift-format")
        try FileManager.default.createDirectory(atPath: root + "/.swift-format", withIntermediateDirectories: true)      // a folder is no config
        #expect(QualityDetection.formatters(configuredIn: root) == [.swiftFormat])
    }
}
