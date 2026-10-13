import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

extension FormatProject {
    /// A folder that `XcodeDiscovery.readInstall` takes for an Xcode, named `name` under the project's temporary folder.
    func standInXcode(_ name: String, version: String) throws -> String {
        let path = project.base + "/" + name + ".app"
        let info = ["CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundleShortVersionString": version]
        try project.write("", to: "Contents/Info.plist", in: path)
        try (info as NSDictionary).write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The project's config with `xcode:` set, which a worktree opened afterwards reads.
    func nameXcode(_ spec: String, formatter: String = FormatProject.appleSwiftFormat) throws {
        try project.write(formatter + "xcode: \"\(spec)\"\n", to: ".xcdev.yml")
    }

    /// Whether xcd looked for an Xcode, which it does by asking Spotlight and `xcode-select`.
    var lookedForAnXcode: Bool {
        fake.calls.contains { ["mdfind", "xcode-select"].contains($0.argv.first) }
    }

    /// The `xcrun` call that looked for swift-format.
    var xcrunCall: Invocation? { fake.calls.first { $0.argv.first == "xcrun" } }
}

/// What `xcd format` does about a file git cannot read, which Xcode's swift-format it uses, and when it writes a log.
@Suite struct FormatServiceFixTests {
    let formatters = FakeFormatters()

    @Test func aFileGitCannotReadIsListedAndTheOthersAreStillFormatted() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        try project.change()
        let old = project.root + "/Sources/App/A.swift"
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: old)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: old) }
        let ctx = try await project.context()
        let report = try await project.service(formatters).format(FormatOptions(), in: ctx)

        #expect(report.failed.map(\.file) == ["Sources/App/A.swift"])
        let message = try #require(report.failed.first?.message)
        #expect(message.hasPrefix("Sources/App/A.swift: git could not say which of its lines changed, so it was left as it was: "))
        #expect(message.contains("\n") == false && message.contains("fatal"))
        #expect(report.failure?.code == .formatFailed && report.failure?.code.exitCode == 1)
        #expect(report.changed.map(\.file) == ["Sources/App/C.swift"])
        #expect(try project.read("Sources/App/C.swift") == "struct C {\n    let c = 1\n}\n")
        #expect(formatters.runs.map(\.file) == [project.root + "/Sources/App/C.swift"])
    }

    @Test func theXcodeTheConfigNamesIsUsedWhenNothingIsPinned() async throws {
        let project = try FormatProject(FormatProject.appleSwiftFormat)
        defer { project.project.remove() }
        try project.change()
        let xcode = try project.standInXcode("Named", version: "27.0")
        try project.nameXcode(xcode)
        let ctx = try await project.context()
        _ = try await project.service(formatters, path: "/nowhere").format(FormatOptions(), in: ctx)
        #expect(project.xcrunCall?.environment == ["DEVELOPER_DIR": xcode + "/Contents/Developer"])
        #expect(project.lookedForAnXcode)
        #expect(!formatters.runs.isEmpty)
        let pinned = try String(contentsOfFile: ctx.paths.stateFile, encoding: .utf8)
        #expect(!pinned.contains(xcode))                                                // nothing was pinned
    }

    @Test func aPinnedXcodeWinsOverTheConfigs() async throws {
        let project = try FormatProject(FormatProject.appleSwiftFormat)
        defer { project.project.remove() }
        try project.change()
        try project.nameXcode(try project.standInXcode("Named", version: "27.0"))
        var ctx = try await project.context()
        ctx.state.xcode = XcodeInstall(path: "/Applications/Xcode-27.app", version: "27.0", build: "27A1")
        _ = try await project.service(formatters, path: "/nowhere").format(FormatOptions(), in: ctx)
        #expect(project.xcrunCall?.environment == ["DEVELOPER_DIR": "/Applications/Xcode-27.app/Contents/Developer"])
        #expect(!project.lookedForAnXcode)
    }

    @Test func anXcodeTheConfigNamesThatIsNotInstalledIsAnErrorAndNothingIsFormatted() async throws {
        let project = try FormatProject(FormatProject.appleSwiftFormat)
        defer { project.project.remove() }
        try project.change()
        try project.nameXcode("99.0")
        let ctx = try await project.context()
        let error = await #expect(throws: XcdError.self) { _ = try await project.service(formatters).format(FormatOptions(), in: ctx) }
        #expect(error?.code == .xcodeMissing && error?.message == "Xcode 99.0 is not installed")
        #expect(try project.read("Sources/App/C.swift") == "struct C {\n\tlet c = 1\n}" && formatters.runs.isEmpty)
    }

    @Test func noXcodeIsLookedForForSwiftFormatOrForAFormatterPath() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        try project.change()
        try project.nameXcode("99.0", formatter: FormatProject.swiftFormat)
        _ = try await project.service(formatters).format(FormatOptions(), in: try await project.context())
        #expect(!project.lookedForAnXcode && !formatters.runs.isEmpty)

        let own = try FormatProject(FormatProject.appleSwiftFormat)
        defer { own.project.remove() }
        try own.change()
        try own.nameXcode("99.0", formatter: FormatProject.appleSwiftFormat + "  path: tools/swift-format\n")
        try own.project.write("#!/bin/sh\n", to: "tools/swift-format")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: own.root + "/tools/swift-format")
        _ = try await own.service(FakeFormatters()).format(FormatOptions(), in: try await own.context())
        #expect(!own.lookedForAnXcode && own.xcrunCall == nil)
    }

    @Test func noLogIsWrittenWhenNoFormatterRan() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        try project.project.git("mv", "Sources/App/A.swift", "Sources/App/Renamed.swift")        // only renamed: nothing to format
        let ctx = try await project.context()
        let report = try await project.service(formatters).format(FormatOptions(), in: ctx)
        #expect(report.files == 1 && formatters.runs.isEmpty)
        #expect(report.log == nil && !report.text.contains("log:"))
        let logs = (try? FileManager.default.contentsOfDirectory(atPath: ctx.paths.logs)) ?? []
        #expect(!logs.contains { $0.hasSuffix("-format.log") })
    }
}
