import Foundation
import Testing
@testable import XcdevKit

@Suite struct ConfigTests {
    static let full = """
    version: 1
    project: SampleApp.xcworkspace
    xcode: 27.0
    schemes:
      app: SampleApp
      test: SampleAppTests
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro", runtime: latest }
      ipad:   { type: "iPad Pro 13-inch (M5)", runtime: "iOS 26.5" }
      watch:  { type: "Apple Watch Series 11 (46mm)", pairWith: iphone }
      mac:    { platform: macOS }
    presets:
      onboarding: { args: ["-resetOnboarding", "YES"], env: { API_ENV: staging } }
    worktrees:
      root: "../{project}.worktrees"
    """

    @Test func parsesFullConfig() throws {
        let config = try ConfigLoader.parse(main: Self.full)
        #expect(config.project == "SampleApp.xcworkspace")
        #expect(config.xcode == "27.0")               // unquoted float scalar stays a string
        #expect(config.allDevices["watch"]?.pairWith == "iphone")
        #expect(config.allDevices["mac"]?.isMac == true)
        #expect(config.presets?["onboarding"]?.env?["API_ENV"] == "staging")
        #expect(config.worktreesRoot == "../{project}.worktrees")
    }

    @Test func defaultsForOptionalSections() throws {
        let config = try ConfigLoader.parse(main: "version: 1\nproject: Package.swift\n")
        #expect(config.allDevices.isEmpty)
        #expect(config.worktreesRoot == "../{project}.worktrees")
    }

    @Test func unknownKeySuggestsClosest() {
        let error = #expect(throws: XcdError.self) {
            try ConfigLoader.parse(main: "version: 1\nproject: A.xcodeproj\ndevics: {}\n")
        }
        #expect(error?.code == .configInvalid)
        #expect(error?.details == ["devics: unknown key (did you mean 'devices'?)"])
        #expect(error?.next?.contains("xcd config show") == true)
    }

    @Test func unknownNestedKeyReportsPath() {
        let yaml = "version: 1\nproject: A.xcodeproj\ndevices:\n  iphone: { type: X, runtme: latest }\n"
        let error = #expect(throws: XcdError.self) { try ConfigLoader.parse(main: yaml) }
        #expect(error?.details == ["devices.iphone.runtme: unknown key (did you mean 'runtime'?)"])
    }

    @Test func reservedKeyIsExplained() {
        let error = #expect(throws: XcdError.self) {
            try ConfigLoader.parse(main: "version: 1\nproject: A.xcodeproj\nlint: {}\n")
        }
        #expect(error?.details.first?.contains("reserved for a future version") == true)
    }

    @Test func missingRequiredKeys() {
        let error = #expect(throws: XcdError.self) { try ConfigLoader.parse(main: "devices: {}\n") }
        #expect(error?.details.sorted() == ["project: is required", "version: is required"])
    }

    @Test func semanticChecks() {
        let yaml = """
        version: 2
        project: A.xcodeproj
        defaultDevice: phone
        devices:
          iphone: { runtime: latest }
          mac: { platform: macOS, type: "Mac" }
          watch: { type: W, pairWith: nope }
        """
        let error = #expect(throws: XcdError.self) { try ConfigLoader.parse(main: yaml) }
        #expect(error?.details == [
            "version: unsupported version 2 (this xcd supports 1)",
            "defaultDevice: 'phone' is not a key under devices",
            "devices.iphone.type: is required unless platform is macOS",
            "devices.mac: set either type or platform: macOS, not both",
            "devices.watch.pairWith: 'nope' is not a key under devices",
        ])
    }

    @Test func pairWithCycleIsRejected() {
        let yaml = """
        version: 1
        project: A.xcodeproj
        devices:
          a: { type: A, pairWith: b }
          b: { type: B, pairWith: a }
        """
        let error = #expect(throws: XcdError.self) { try ConfigLoader.parse(main: yaml) }
        #expect(error?.code == .configInvalid)
        #expect(error?.details == [
            "devices.a.pairWith: 'b' also has pairWith; pairing chains are not supported",
            "devices.b.pairWith: 'a' also has pairWith; pairing chains are not supported",
        ])
    }

    @Test func invalidPlatformValue() {
        let yaml = "version: 1\nproject: A.xcodeproj\ndevices:\n  m: { platform: linux }\n"
        let error = #expect(throws: XcdError.self) { try ConfigLoader.parse(main: yaml) }
        #expect(error?.details == ["devices.m.platform: must be one of: macOS"])
    }

    @Test func invalidYAML() {
        let error = #expect(throws: XcdError.self) { try ConfigLoader.parse(main: "version: [1\n") }
        #expect(error?.code == .configInvalid)
        #expect(error?.message.contains("not valid YAML") == true)
    }

    @Test func localOverrideDeepMerges() throws {
        let local = """
        defaultDevice: ipad
        devices:
          iphone: { runtime: "iOS 26.5" }
        """
        let config = try ConfigLoader.parse(main: Self.full, local: local)
        #expect(config.defaultDevice == "ipad")
        #expect(config.allDevices["iphone"] == DeviceSpec(type: "iPhone 18 Pro", runtime: "iOS 26.5"))
        #expect(config.allDevices.count == 4)
    }

    @Test func loadReadsFilesAndReportsMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let missing = #expect(throws: XcdError.self) { try ConfigLoader.load(worktreeRoot: dir, projectRoot: dir) }
        #expect(missing?.code == .configMissing)
        #expect(missing?.next == "run `xcd init` in the project root")

        try "version: 1\nproject: A.xcodeproj\n".write(toFile: dir + "/.xcdev.yml", atomically: true, encoding: .utf8)
        try "xcode: beta\n".write(toFile: dir + "/.xcdev.local.yml", atomically: true, encoding: .utf8)
        #expect(try ConfigLoader.load(worktreeRoot: dir, projectRoot: dir).xcode == "beta")
    }

    @Test func versionTypeError() {
        let error = #expect(throws: XcdError.self) { try ConfigLoader.parse(main: "version: one\nproject: A.xcodeproj\n") }
        #expect(error?.details == ["version: expected an integer"])
    }

    @Test func projectTypeError() {
        let error = #expect(throws: XcdError.self) { try ConfigLoader.parse(main: "version: 1\nproject: [a]\n") }
        #expect(error?.details == ["project: expected a string"])
    }

    @Test func presetsArgsTypeError() {
        let yaml = "version: 1\nproject: A.xcodeproj\npresets:\n  p:\n    args: \"x\"\n"
        let error = #expect(throws: XcdError.self) { try ConfigLoader.parse(main: yaml) }
        #expect(error?.details == ["presets.p.args: expected a list of strings"])
    }

    @Test func presetsArgsListIndexError() {
        let yaml = "version: 1\nproject: A.xcodeproj\npresets:\n  p:\n    args: [a, [b]]\n"
        let error = #expect(throws: XcdError.self) { try ConfigLoader.parse(main: yaml) }
        #expect(error?.details == ["presets.p.args[1]: expected a string"])
    }

    @Test func devicesTypeError() {
        let error = #expect(throws: XcdError.self) { try ConfigLoader.parse(main: "version: 1\nproject: A.xcodeproj\ndevices: [x]\n") }
        #expect(error?.details == ["devices: expected a mapping"])
    }

    @Test func localFileTypoIsAttributedCorrectly() {
        let error = #expect(throws: XcdError.self) {
            try ConfigLoader.parse(main: "version: 1\nproject: A.xcodeproj\n", local: "devics: {}\n")
        }
        #expect(error?.code == .configInvalid)
        #expect(error?.message.contains(".xcdev.local.yml") == true)
        #expect(error?.details == ["devics: unknown key (did you mean 'devices'?)"])
    }

    @Test func localFileOnlyPartialConfigDoesNotRequiredMissingFields() throws {
        let main = """
        version: 1
        project: A.xcodeproj
        devices:
          ipad: { type: "iPad" }
        """
        let local = "defaultDevice: ipad\n"
        let config = try ConfigLoader.parse(main: main, local: local)
        #expect(config.defaultDevice == "ipad")
        #expect(config.project == "A.xcodeproj")
    }

    @Test func logsMaxFollowDefaultsAndParses() throws {
        #expect(try ConfigLoader.parse(main: "version: 1\nproject: A.xcodeproj").maxLogFollow == .seconds(300))
        let config = try ConfigLoader.parse(main: "version: 1\nproject: A.xcodeproj\nlogs: { maxFollow: 90s }")
        #expect(config.maxLogFollow == .seconds(90))
    }

    @Test func logsMaxFollowMustBeADuration() {
        let error = #expect(throws: XcdError.self) {
            try ConfigLoader.parse(main: "version: 1\nproject: A.xcodeproj\nlogs: { maxFollow: forever }")
        }
        #expect(error?.code == .configInvalid)
        #expect(error?.details.contains { $0.contains("logs.maxFollow") && $0.contains("forever") } == true)
    }
}
