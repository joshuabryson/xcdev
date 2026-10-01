import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct XcodeTests {
    let installs = [
        XcodeInstall(path: "/Applications/Xcode.app", version: "27.0", build: "27A266a"),
        XcodeInstall(path: "/Applications/Xcode-26.5.app", version: "26.5", build: "17F42"),
        XcodeInstall(path: "/Applications/Xcode-beta.app", version: "27.1", build: "27B5024e"),
    ]

    @Test func versionOrderingAndPrefix() {
        #expect(Version("27.0")! == Version("27")!)
        #expect(Version("26.5")! < Version("27.0")!)
        #expect(Version("27.0.1")!.hasPrefix(Version("27.0")!))
        #expect(Version("beta") == nil)
    }

    @Test func systemUsesXcodeSelectTarget() throws {
        let x = try XcodeResolver.resolve(spec: nil, installs: installs,
                                          selectedDeveloperDir: "/Applications/Xcode-26.5.app/Contents/Developer")
        #expect(x.version == "26.5")
    }

    @Test func systemFallsBackToNewestStableWhenCLTSelected() throws {
        let x = try XcodeResolver.resolve(spec: "system", installs: installs,
                                          selectedDeveloperDir: "/Library/Developer/CommandLineTools")
        #expect(x.version == "27.0")
    }

    @Test func latestBetaVersionAndPath() throws {
        #expect(try XcodeResolver.resolve(spec: "latest", installs: installs, selectedDeveloperDir: nil).version == "27.0")
        #expect(try XcodeResolver.resolve(spec: "beta", installs: installs, selectedDeveloperDir: nil).version == "27.1")
        #expect(try XcodeResolver.resolve(spec: "26", installs: installs, selectedDeveloperDir: nil).version == "26.5")
        #expect(try XcodeResolver.resolve(spec: "27.0", installs: installs, selectedDeveloperDir: nil).build == "27A266a")
        #expect(try XcodeResolver.resolve(spec: "/Applications/Xcode-beta.app/", installs: installs, selectedDeveloperDir: nil).version == "27.1")
    }

    @Test func missingListsInstalled() {
        let error = #expect(throws: XcdError.self) {
            try XcodeResolver.resolve(spec: "25.0", installs: installs, selectedDeveloperDir: nil)
        }
        #expect(error?.code == .xcodeMissing)
        #expect(error?.message == "Xcode 25.0 is not installed")
        #expect(error?.details.first == "installed: Xcode 27.1 (27B5024e) /Applications/Xcode-beta.app")
        #expect(error?.next == "set `xcode:` in .xcdev.yml to an installed version, e.g. \"27.0\"")
    }

    @Test func garbageSpecIsConfigError() {
        let error = #expect(throws: XcdError.self) {
            try XcodeResolver.resolve(spec: "newest", installs: installs, selectedDeveloperDir: nil)
        }
        #expect(error?.code == .configInvalid)
    }

    @Test func discoveryReadsBundlesFromSpotlightAndApplications() async throws {
        let apps = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: apps) }
        try Self.makeFakeXcode(at: apps + "/Xcode.app", version: "27.0", build: "27A266a")
        try Self.makeFakeXcode(at: apps + "/Xcode-beta.app", version: "27.1", build: "27B5024e")
        try FileManager.default.createDirectory(atPath: apps + "/Notes.app", withIntermediateDirectories: true)

        let fake = FakeProcessRunner()
        fake.stub(["mdfind"], stdout: apps + "/Xcode.app\n")          // duplicate of the directory scan
        fake.stub(["xcode-select", "-p"], stdout: apps + "/Xcode.app/Contents/Developer\n")
        let discovery = XcodeDiscovery(runner: fake, applicationsDirectories: [apps])

        let found = await discovery.installs()
        #expect(found.map(\.version) == ["27.1", "27.0"])
        let chosen = try await discovery.resolve(spec: nil)
        #expect(chosen.build == "27A266a")
        #expect(chosen.developerDir == apps + "/Xcode.app/Contents/Developer")
    }

    static func makeFakeXcode(at path: String, version: String, build: String) throws {
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        (["CFBundleShortVersionString": version] as NSDictionary).write(toFile: path + "/Contents/Info.plist", atomically: true)
        (["ProductBuildVersion": build] as NSDictionary).write(toFile: path + "/Contents/version.plist", atomically: true)
    }
}
