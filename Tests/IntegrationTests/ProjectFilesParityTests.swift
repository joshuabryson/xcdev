import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"

/// What `xcd init` reads from the project files matches what real xcodebuild reports for the same project: the
/// SampleApp fixture, and the hand-written projects the unit tests use (whose rules for autocreated and package
/// schemes were worked out by watching Xcode). Runs xcodebuild -list and -showBuildSettings on copies; neither needs
/// sources, creates simulators, or (with the paths xcd passes) writes into Xcode's DerivedData.
@Suite(.enabled(if: enabled, "set XCD_INTEGRATION=1 to run (needs Xcode)"))
struct ProjectFilesParityTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("xcd parity \(UUID().uuidString)").path
    var root: String { base + "/Sample App" }
    static let handWritten = repoRoot + "/Tests/XcdevKitTests/Fixtures/ProjectFiles/"

    func copy(_ fixture: String, to path: String = "") throws {
        let fm = FileManager.default
        let destination = root + (path.isEmpty ? "" : "/" + path)
        try fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.copyItem(atPath: fixture, toPath: destination)
    }

    func write(_ text: String, to path: String) throws {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    /// A package xcodebuild can load: each target gets one source file.
    func package(_ folder: String, manifest: String, targets: [(name: String, test: Bool)]) throws {
        try write("// swift-tools-version: 6.0\nimport PackageDescription\n" + manifest, to: folder + "/Package.swift")
        for target in targets {
            try write(target.test ? "import Testing\n" : "public let x = 1\n",
                      to: folder + (target.test ? "/Tests/" : "/Sources/") + target.name + "/File.swift")
        }
    }

    func scheme(_ name: String, id: String, target: String, container: String) throws {
        try write("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Scheme version = "1.7"><BuildAction><BuildActionEntries><BuildActionEntry buildForTesting = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "\(id)" BlueprintName = "\(target)"
             ReferencedContainer = "container:\(container)"></BuildableReference>
            </BuildActionEntry></BuildActionEntries></BuildAction></Scheme>
            """, to: name)
    }

    /// Tier 1's result, and xcodebuild's for the same container.
    func detectBothWays(_ container: String) async throws -> (files: DetectedProject, xcodebuild: DetectedProject) {
        let runner = SystemProcessRunner()
        func detector(_ scratch: String) -> ProjectDetector {
            ProjectDetector(runner: runner, developerDir: nil, scratch: base + "/" + scratch, xcodeDerivedData: base + "/no DerivedData")
        }
        let files = try await detector("files").detect(root: root, container: container)
        let resolved = try ProjectContainer.resolve(config: XcdevConfig(version: 1, project: container), worktreeRoot: root)
        let names = [URL(fileURLWithPath: container).deletingPathExtension().lastPathComponent, "Sample App"]
        let xcodebuild = try await detector("xcodebuild").detectWithXcodebuild(resolved, root: root, container: container,
                                                                                names: names, notes: [])
        return (files, xcodebuild)
    }

    func expectSame(_ container: String) async throws {
        let (files, xcodebuild) = try await detectBothWays(container)
        #expect(files.notes.isEmpty, "the project files weren't enough: \(files.notes)")
        // xcodebuild can't show build settings for a scheme that only tests (no destinations to build for); that's
        // its own limit, not a difference in what the files say.
        #expect(xcodebuild.notes.allSatisfy { $0.contains("Found no destinations for the scheme") }, "\(xcodebuild.notes)")
        #expect(files.schemes == xcodebuild.schemes)
        #expect(files.appSchemes == xcodebuild.appSchemes)
        #expect(files.testSchemes == xcodebuild.testSchemes)
        #expect(files.platforms == xcodebuild.platforms)
        #expect(files.deviceFamilies == xcodebuild.deviceFamilies)
    }

    @Test func sampleApp() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try copy(repoRoot + "/Fixtures/SampleApp")
        try await expectSame("SampleApp.xcodeproj")
    }

    /// Autocreated target schemes (never for tests), a watch app, this user's scheme, and both kinds of local package.
    @Test func phone() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try copy(Self.handWritten + "Phone")
        try scheme("Phone.xcodeproj/xcuserdata/\(NSUserName()).xcuserdatad/xcschemes/PhoneUITests.xcscheme",
                   id: "A10000000000000000000103", target: "PhoneUITests", container: "Phone.xcodeproj")
        try package("Packages/Shared", manifest: """
            let package = Package(name: "Shared", products: [.library(name: "Shared", targets: ["Shared"]),
                .library(name: "SharedTestSupport", targets: ["SharedTestSupport"])],
              targets: [.target(name: "Shared"), .target(name: "SharedTestSupport", dependencies: ["Shared"]),
                .testTarget(name: "SharedTests", dependencies: ["Shared"])])
            """, targets: [("Shared", false), ("SharedTestSupport", false), ("SharedTests", true)])
        try package("Packages/Acceptance", manifest: """
            let package = Package(name: "Acceptance", dependencies: [.package(name: "Shared", path: "../Shared")],
              targets: [.executableTarget(name: "victim", dependencies: [.product(name: "Shared", package: "Shared")]),
                .testTarget(name: "AcceptanceTests", dependencies: [.product(name: "Shared", package: "Shared")])])
            """, targets: [("victim", false), ("AcceptanceTests", true)])
        try await expectSame("Phone.xcodeproj")
    }

    /// A workspace of two projects (one in a workspace group) and a package folder.
    @Test func suiteWorkspace() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try copy(Self.handWritten + "Suite")
        try package("Packages/Feature", manifest: """
            let package = Package(name: "Feature", products: [.library(name: "Feature", targets: ["Feature"])],
              targets: [.target(name: "Feature"), .testTarget(name: "FeatureTests", dependencies: ["Feature"])])
            """, targets: [("Feature", false), ("FeatureTests", true)])
        try await expectSame("Suite.xcworkspace")
    }

    /// A Mac Catalyst app counts as iOS both ways.
    @Test func catalystApp() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try copy(repoRoot + "/Fixtures/SampleApp")
        let pbxproj = root + "/SampleApp.xcodeproj/project.pbxproj"
        let text = try String(contentsOfFile: pbxproj, encoding: .utf8)
        try text.replacingOccurrences(of: "PRODUCT_BUNDLE_IDENTIFIER = dev.xcdev.SampleApp;",
                                      with: "PRODUCT_BUNDLE_IDENTIFIER = dev.xcdev.SampleApp;\n\t\t\t\tSUPPORTS_MACCATALYST = YES;")
            .write(toFile: pbxproj, atomically: true, encoding: .utf8)
        try await expectSame("SampleApp.xcodeproj")
    }

    /// A scheme that builds a project outside the container: tier 1 must not be confident, since xcodebuild can't
    /// read that scheme's build settings.
    @Test func aSchemeBuildingAnOutsideProject() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try copy(repoRoot + "/Fixtures/SampleApp")
        try copy(Self.handWritten + "Suite/Tools/Tools.xcodeproj", to: "Sub/Other.xcodeproj")
        try scheme("SampleApp.xcodeproj/xcshareddata/xcschemes/Main.xcscheme", id: "D10000000000000000000101", target: "Mac Tool",
                   container: "Sub/Other.xcodeproj")
        let (files, xcodebuild) = try await detectBothWays("SampleApp.xcodeproj")
        #expect(files.notes.first?.hasPrefix("scheme \"Main\" builds Mac Tool in Sub/Other.xcodeproj") == true, "\(files.notes)")
        #expect(xcodebuild.notes.contains { $0.hasPrefix("could not read the build settings of scheme \"Main\"") }, "\(xcodebuild.notes)")
        #expect(files.platforms == [.iOS] && files.appSchemes == ["SampleApp"])
    }
}
