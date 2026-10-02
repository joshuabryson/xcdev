import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct ProjectDetectionTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xcd detect \(UUID().uuidString)/Sample App").path
    let fake = FakeProcessRunner()
    var scratch: String { root + "/../scratch" }

    func make(_ paths: [String]) throws {
        let fm = FileManager.default
        for path in paths {
            let full = root + "/" + path
            if path.hasSuffix("Package.swift") {
                try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                fm.createFile(atPath: full, contents: Data())
            } else {
                try fm.createDirectory(atPath: full, withIntermediateDirectories: true)
            }
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }

    @Test func appTargetsFromRecordedBuildSettings() {
        #expect(AppTarget.parse(Data(Fixture.string("build-settings-scheme-app.json").utf8))
                == [AppTarget(name: "SampleApp", isApp: true, platforms: [.iOS], deviceFamilies: [1, 2])])
        let watch = AppTarget.parse(Data(Fixture.string("build-settings-scheme-watch.json").utf8))
        #expect(watch.map(\.name) == ["SampleWatch Watch App", "SampleApp"])
        #expect(watch.first?.platforms == [.watchOS] && watch.first?.deviceFamilies == [4])
        // `-showBuildSettings -alltargets` lists a test host twice; packages print `[]`.
        let twice = #"[{"target":"A","buildSettings":{"PRODUCT_TYPE":"com.apple.product-type.application"}},{"target":"A","buildSettings":{}}]"#
        #expect(AppTarget.parse(Data(twice.utf8)).count == 1)
        #expect(AppTarget.parse(Data("[\n\n]\n".utf8)).isEmpty)
    }

    @Test func packageManifestFromRecordedDump() throws {
        let sample = try PackageManifest.parse(Data(Fixture.string("swift-package-dump.json").utf8))
        #expect(sample == PackageManifest(name: "SamplePackage", platforms: [.iOS, .macOS]))
        let multi = try PackageManifest.parse(Data(Fixture.string("swift-package-dump-ios-watch.json").utf8))
        #expect(multi == PackageManifest(name: "Multi Lib", platforms: [.iOS, .watchOS]))
    }

    @Test func prefersTheShallowestWorkspaceThenProjectThenPackage() throws {
        defer { cleanUp() }
        try make(["Sample App.xcodeproj", "Sample App.xcworkspace", "Package.swift", "ios/Other.xcodeproj",
                  ".hidden/X.xcworkspace", "Pods/Pods.xcodeproj"])
        #expect(ProjectDetector.containers(in: root) == ["Sample App.xcworkspace"])
    }

    @Test func severalContainersAtTheBestLevelAreAllReturnedFolderNameFirst() throws {
        defer { cleanUp() }
        try make(["Admin.xcodeproj", "Sample App.xcodeproj"])
        #expect(ProjectDetector.containers(in: root) == ["Sample App.xcodeproj", "Admin.xcodeproj"])
    }

    @Test func looksOneFolderDown() throws {
        defer { cleanUp() }
        try make(["app/App.xcodeproj", "app/deeper/Deep.xcworkspace", "README"])
        #expect(ProjectDetector.containers(in: root) == ["app/App.xcodeproj"])
        try FileManager.default.removeItem(atPath: root + "/app")
        #expect(ProjectDetector.containers(in: root).isEmpty)
    }

    @Test func detectsAppSchemesAndEveryPlatformAcrossSchemes() async throws {
        defer { cleanUp() }
        try make(["SampleApp.xcodeproj"])
        fake.stub(["xcrun", "xcodebuild", "-list"], stdout: Fixture.string("xcodebuild-list-watch.json"))
        fake.stub(["xcrun", "xcodebuild", "-showBuildSettings"]) { inv in
            let scheme = inv.arguments[inv.arguments.firstIndex(of: "-scheme")! + 1]
            return ProcessOutput(stdout: Fixture.string(scheme == "SampleApp" ? "build-settings-scheme-app.json"
                                                                                : "build-settings-scheme-watch.json"))
        }
        let detected = try await ProjectDetector(runner: fake, developerDir: nil, scratch: scratch)
            .detect(root: root, container: "SampleApp.xcodeproj")
        #expect(detected == DetectedProject(container: "SampleApp.xcodeproj", kind: .project,
                                            schemes: ["SampleApp", "SampleWatch Watch App"],
                                            appSchemes: ["SampleApp"], testSchemes: ["SampleApp"],
                                            platforms: [.iOS, .watchOS], deviceFamilies: [1, 2]))
        // xcodebuild keeps its state in the scratch folder, never in the project.
        let settings = try #require(fake.calls.first { $0.arguments.contains("-showBuildSettings") }).arguments
        #expect(settings.contains(scratch + "/.xcdev/DerivedData"))
        let list = try #require(fake.calls.first { $0.arguments.contains("-list") }).arguments
        #expect(list.contains(scratch + "/.xcdev/SourcePackages"))
    }

    @Test func detectsAPackagesDeclaredPlatformsAndItsAllInOneScheme() async throws {
        defer { cleanUp() }
        try make(["Package.swift"])
        fake.stub(["xcrun", "xcodebuild", "-list"], stdout: Fixture.string("xcodebuild-list-multipackage.json"))
        fake.stub(["xcrun", "swift", "package"], stdout: Fixture.string("swift-package-dump-ios-watch.json"))
        let detected = try await ProjectDetector(runner: fake, developerDir: nil, scratch: scratch)
            .detect(root: root, container: "Package.swift")
        #expect(detected.kind == .package && detected.platforms == [.iOS, .watchOS])
        #expect(detected.appSchemes == ["Multi Lib-Package", "A", "B"])
        let dump = try #require(fake.calls.first { $0.arguments.starts(with: ["swift", "package"]) })
        #expect(dump.arguments == ["swift", "package", "--scratch-path", scratch + "/swiftpm", "dump-package"])
        #expect(dump.workingDirectory == URL(fileURLWithPath: root).standardizedFileURL.path)
    }

    @Test func testSchemesPreferTheAppsTestsScheme() {
        #expect(ProjectDetector.testSchemes(["App", "AppUITests", "AppTests", "KitTests"], app: "App")
                == ["AppTests", "KitTests", "AppUITests", "App"])
        #expect(ProjectDetector.testSchemes(["App"], app: "App") == ["App"])
    }

    @Test func aSchemeWhoseBuildSettingsFailIsNamedInANote() async throws {
        defer { cleanUp() }
        try make(["SampleApp.xcodeproj"])
        fake.stub(["xcrun", "xcodebuild", "-list"], stdout: Fixture.string("xcodebuild-list-watch.json"))
        fake.stub(["xcrun", "xcodebuild", "-showBuildSettings"]) { inv in
            let scheme = inv.arguments[inv.arguments.firstIndex(of: "-scheme")! + 1]
            if scheme == "SampleApp" { return ProcessOutput(stdout: Fixture.string("build-settings-scheme-app.json")) }
            return ProcessOutput(exitCode: 65, stderr: "note: Using new build system\nxcodebuild: error: Unable to find a destination matching the provided destination specifier\n")
        }
        let detector = ProjectDetector(runner: fake, developerDir: nil, scratch: scratch)
        let detected = try await detector.detect(root: root, container: "SampleApp.xcodeproj")
        #expect(detected.platforms == [.iOS] && detected.appSchemes == ["SampleApp"])
        #expect(detected.notes == [
            "could not read the build settings of scheme \"SampleWatch Watch App\" (`xcodebuild -showBuildSettings` exit 65: "
                + "xcodebuild: error: Unable to find a destination matching the provided destination specifier), "
                + "so its platforms are not included"])

        // Every scheme failing (here: timing out) names each scheme, not a guess about the platform.
        fake.stub(["xcrun", "xcodebuild", "-showBuildSettings"]) { _ in
            throw XcdError(.timeout, "`xcrun xcodebuild -showBuildSettings` did not finish within 2m")
        }
        let failed = try await detector.detect(root: root, container: "SampleApp.xcodeproj")
        #expect(failed.platforms.isEmpty && failed.appSchemes.isEmpty)
        #expect(failed.notes.count == 2)
        #expect(failed.notes.first == "could not read the build settings of scheme \"SampleApp\" "
                + "(`xcrun xcodebuild -showBuildSettings` did not finish within 2m), so its platforms are not included")
    }

    @Test func theAppSchemeIsReadEvenPastTheSchemeCap() async throws {
        defer { cleanUp() }
        try make(["SampleApp.xcworkspace"])
        // A CocoaPods workspace: xcodebuild lists the pods' schemes alphabetically, the app's well past the cap.
        let pods = ["Alamofire", "Charts", "Firebase", "GoogleUtilities", "Kingfisher", "Lottie", "Moya", "Nuke",
                    "Pods-SampleApp", "Realm", "RxSwift", "SDWebImage", "SnapKit", "SwiftyJSON"]
        let schemes = pods + ["SampleApp", "SampleAppTests"]
        let list = try String(decoding: JSONSerialization.data(withJSONObject: ["workspace": ["name": "SampleApp", "schemes": schemes]]),
                              as: UTF8.self)
        fake.stub(["xcrun", "xcodebuild", "-list"], stdout: list)
        let framework = #"[{"target":"Pod","buildSettings":{"PRODUCT_TYPE":"com.apple.product-type.framework","SUPPORTED_PLATFORMS":"iphoneos iphonesimulator"}}]"#
        fake.stub(["xcrun", "xcodebuild", "-showBuildSettings"]) { inv in
            let scheme = inv.arguments[inv.arguments.firstIndex(of: "-scheme")! + 1]
            return ProcessOutput(stdout: scheme == "SampleApp" ? Fixture.string("build-settings-scheme-app.json") : framework)
        }
        let detected = try await ProjectDetector(runner: fake, developerDir: nil, scratch: scratch)
            .detect(root: root, container: "SampleApp.xcworkspace")
        #expect(detected.kind == .workspace && detected.schemes == schemes)
        #expect(detected.appSchemes == ["SampleApp"] && detected.platforms == [.iOS] && detected.deviceFamilies == [1, 2])
        let read = fake.calls.filter { $0.arguments.contains("-showBuildSettings") }
            .map { $0.arguments[$0.arguments.firstIndex(of: "-scheme")! + 1] }
        #expect(read.count == ProjectDetector.maxSchemes && read.contains("SampleApp"))
        #expect(!read.contains("SampleAppTests") && !read.contains("Pods-SampleApp"))
        // The schemes left out are named, never dropped silently.
        #expect(detected.notes == ["read the build settings of 12 of 16 schemes; not read: SnapKit, SwiftyJSON, "
                                   + "Pods-SampleApp, SampleAppTests (set schemes.app in .xcdev.yml if the app is among them)"])

        // A scheme named like the folder is read first too, when the container is named otherwise.
        try make(["Shop.xcworkspace"])
        let byFolder = try String(decoding: JSONSerialization.data(withJSONObject: ["workspace": ["name": "Shop", "schemes": pods + ["Sample App"]]]),
                                  as: UTF8.self)
        fake.stub(["xcrun", "xcodebuild", "-list"], stdout: byFolder)
        fake.stub(["xcrun", "xcodebuild", "-showBuildSettings"]) { inv in
            let scheme = inv.arguments[inv.arguments.firstIndex(of: "-scheme")! + 1]
            return ProcessOutput(stdout: scheme == "Sample App" ? Fixture.string("build-settings-scheme-app.json") : framework)
        }
        let shop = try await ProjectDetector(runner: fake, developerDir: nil, scratch: scratch)
            .detect(root: root, container: "Shop.xcworkspace")
        #expect(shop.appSchemes == ["Sample App"])
    }

    @Test func aSchemeNamedLikeTheFolderIsTheRecommendedApp() async throws {
        defer { cleanUp() }
        try make(["Shop.xcworkspace"])
        fake.stub(["xcrun", "xcodebuild", "-list"],
                  stdout: #"{"workspace":{"name":"Shop","schemes":["Admin","Sample App"]}}"#)
        fake.stub(["xcrun", "xcodebuild", "-showBuildSettings"], stdout: Fixture.string("build-settings-scheme-app.json"))
        let detected = try await ProjectDetector(runner: fake, developerDir: nil, scratch: scratch)
            .detect(root: root, container: "Shop.xcworkspace")
        #expect(detected.appSchemes == ["Sample App", "Admin"])
        #expect(detected.testSchemes == ["Sample App"])
    }
}
