import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Tier 1 of `xcd init`'s detection: the hand-written projects in Fixtures/ProjectFiles, read without xcodebuild.
@Suite struct ProjectFilesTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("xcd files \(UUID().uuidString)").path
    let fake = FakeProcessRunner()
    var root: String { base + "/Sample App" }
    var scratch: String { base + "/scratch" }

    func cleanUp() { try? FileManager.default.removeItem(atPath: base) }

    func write(_ text: String, to path: String) throws {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    func detector() -> ProjectDetector {
        ProjectDetector(runner: fake, developerDir: nil, scratch: scratch, xcodeDerivedData: base + "/no DerivedData")
    }

    /// `swift package dump-package` answers per package folder, from hand-written manifests.
    func stubPackages(_ manifests: [String: String]) {
        fake.stub(["xcrun", "swift", "package"]) { inv in
            let folder = URL(fileURLWithPath: inv.workingDirectory ?? "").lastPathComponent
            guard let json = manifests[folder] else { return ProcessOutput(exitCode: 1, stderr: "error: no manifest\n") }
            return ProcessOutput(stdout: json)
        }
    }

    static let shared = """
        {"name": "Shared", "products": [
          {"name": "Shared", "targets": ["Shared"], "type": {"library": ["automatic"]}},
          {"name": "SharedTestSupport", "targets": ["SharedTestSupport"], "type": {"library": ["automatic"]}}],
         "targets": [
          {"name": "Shared", "type": "regular", "dependencies": []},
          {"name": "SharedTestSupport", "type": "regular", "dependencies": [{"byName": ["Shared", null]}]},
          {"name": "SharedTests", "type": "test", "dependencies": [{"byName": ["Shared", null]}]}]}
        """
    /// Like a package that only holds cross-package tests: no products, an executable, tests of other packages.
    static let acceptance = """
        {"name": "Acceptance", "products": [],
         "targets": [
          {"name": "victim", "type": "executable", "dependencies": [{"product": ["Shared", "Shared", null, null]}]},
          {"name": "AcceptanceTests", "type": "test", "dependencies": [{"product": ["Shared", "Shared", null, null]}]}]}
        """

    /// The Phone fixture plus what git wouldn't keep in the fixture: a user scheme and the packages' folders.
    func makePhone() throws {
        try Fixture.copy("ProjectFiles/Phone", to: root)
        try write(Self.scheme(building: "A10000000000000000000103", "PhoneUITests", container: "Phone.xcodeproj"),
                  to: "Phone.xcodeproj/xcuserdata/someone.xcuserdatad/xcschemes/PhoneUITests.xcscheme")
        try write("", to: "Packages/Shared/Package.swift")
        try write("", to: "Packages/Acceptance/Package.swift")
        stubPackages(["Shared": Self.shared, "Acceptance": Self.acceptance])
    }

    static func scheme(building id: String, _ name: String, container: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme version = "1.7">
           <BuildAction>
              <BuildActionEntries>
                 <BuildActionEntry buildForTesting = "YES">
                    <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "\(id)"
                       BlueprintName = "\(name)" ReferencedContainer = "container:\(container)">
                    </BuildableReference>
                 </BuildActionEntry>
              </BuildActionEntries>
           </BuildAction>
        </Scheme>
        """
    }

    static func autocreate(_ on: Bool) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded</key><\(on)/></dict></plist>
        """
    }

    var xcodebuildCalls: [Invocation] { fake.calls.filter { $0.arguments.first == "xcodebuild" } }

    @Test func aProjectsSchemesAndPlatformsComeFromItsFilesWithoutXcodebuild() async throws {
        defer { cleanUp() }
        try makePhone()
        let detected = try await detector().detect(root: root, container: "Phone.xcodeproj")
        // Shared and user scheme files, a scheme per target no scheme builds (never for test bundles), a scheme per
        // product of a package reference, and for a package folder its executables and its tests no product covers.
        #expect(detected == DetectedProject(
            container: "Phone.xcodeproj", kind: .project,
            schemes: ["AcceptanceTests", "Kit", "Phone", "Phone Watch App", "PhoneUITests", "Shared", "SharedTestSupport", "victim"],
            appSchemes: ["Phone"], testSchemes: ["AcceptanceTests", "PhoneUITests", "Phone"],
            platforms: [.iOS, .watchOS], deviceFamilies: [1, 2]))
        #expect(xcodebuildCalls.isEmpty)
        // dump-package evaluates only the manifests, each with its build folder in the scratch folder.
        let dumps = fake.calls.filter { $0.arguments.starts(with: ["swift", "package"]) }
        #expect(dumps.count == 2)
        #expect(dumps.allSatisfy { $0.arguments[2] == "--scratch-path" && $0.arguments[3].hasPrefix(scratch + "/") && $0.arguments.last == "dump-package" })
        // With no git on PATH, SwiftPM doesn't run `git status` in the project's repository (which can rewrite its index).
        #expect(dumps.allSatisfy { $0.environment["PATH"] == "/var/empty" })
    }

    @Test func eachSchemeBuildsItsTargetsWithTheirPlatforms() async throws {
        defer { cleanUp() }
        try makePhone()
        let outcome = await ProjectFileReader(runner: fake, developerDir: nil, scratch: scratch)
            .read(.project(root + "/Phone.xcodeproj"))
        guard case .confident(let schemes) = outcome else { Issue.record("\(outcome)"); return }
        let byName = Dictionary(uniqueKeysWithValues: schemes.map { ($0.name, $0.targets) })
        // SDKROOT from the project's configurations; the watch app sets its own.
        #expect(byName["Phone"] == [AppTarget(name: "Phone", isApp: true, platforms: [.iOS], deviceFamilies: [1, 2])])
        #expect(byName["Phone Watch App"] == [AppTarget(name: "Phone Watch App", isApp: true, platforms: [.watchOS], deviceFamilies: [4])])
        #expect(byName["Kit"] == [AppTarget(name: "Kit", isApp: false, platforms: [.iOS], deviceFamilies: [1])])
        #expect(byName["PhoneUITests"]?.map(\.name) == ["PhoneUITests"])
        #expect(byName["Shared"] == [] && byName["victim"] == [])                // package schemes build no app
    }

    @Test func withAutocreationOffOnlySchemeFilesCount() async throws {
        defer { cleanUp() }
        try makePhone()
        try write(Self.autocreate(false), to: "Phone.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings")
        let detected = try await detector().detect(root: root, container: "Phone.xcodeproj")
        #expect(detected.schemes == ["Phone", "PhoneUITests"])
        #expect(detected.appSchemes == ["Phone"] && detected.platforms == [.iOS] && detected.notes.isEmpty)
        #expect(fake.calls.isEmpty)                                              // no packages to read either
    }

    @Test func anSDKROOTAnXcconfigSetsToAnExpressionIsNotEnough() async throws {
        defer { cleanUp() }
        try Fixture.copy("ProjectFiles/Configured", to: root)
        let reader = ProjectFileReader(runner: fake, developerDir: nil, scratch: scratch)
        #expect(await reader.read(.project(root + "/Configured.xcodeproj"))
                == .unsure("the project files don't say which platform Configured builds for (its SDKROOT is $(APP_SDK) in App.xcconfig)"))
        try FileManager.default.removeItem(atPath: root + "/App.xcconfig")
        #expect(await reader.read(.project(root + "/Configured.xcodeproj"))
                == .unsure("the project files don't say which platform Configured builds for "
                           + "(its SUPPORTED_PLATFORMS may come from App.xcconfig, which couldn't be read)"))
    }

    @Test func plainXcconfigLinesAreRead() async throws {
        defer { cleanUp() }
        try Fixture.copy("ProjectFiles/Configured", to: root)
        try write("// the app's settings\n#include \"Shared/Base.xcconfig\"\n#include? \"Local.xcconfig\"\nPRODUCT_NAME = Configured\n",
                  to: "App.xcconfig")
        try write("SDKROOT = iphoneos // the iOS SDK\nTARGETED_DEVICE_FAMILY = 1,2;\n", to: "Shared/Base.xcconfig")
        let outcome = await ProjectFileReader(runner: fake, developerDir: nil, scratch: scratch)
            .read(.project(root + "/Configured.xcodeproj"))
        #expect(outcome == .confident([.init(name: "Configured", targets: [
            AppTarget(name: "Configured", isApp: true, platforms: [.iOS], deviceFamilies: [1, 2])])]))
    }

    @Test func aBuildSettingExpressionIsNotEvaluated() async throws {
        defer { cleanUp() }
        try makePhone()
        let pbxproj = root + "/Phone.xcodeproj/project.pbxproj"
        let text = try String(contentsOfFile: pbxproj, encoding: .utf8)
        try text.replacingOccurrences(of: "SDKROOT = watchos;", with: "SDKROOT = \"$(WATCH_SDK)\";")
            .write(toFile: pbxproj, atomically: true, encoding: .utf8)
        let outcome = await ProjectFileReader(runner: fake, developerDir: nil, scratch: scratch)
            .read(.project(root + "/Phone.xcodeproj"))
        #expect(outcome == .unsure("the project files don't say which platform Phone Watch App builds for (its SDKROOT is $(WATCH_SDK))"))
    }

    @Test func anUnreadablePackageManifestIsNotEnough() async throws {
        defer { cleanUp() }
        try makePhone()
        stubPackages(["Shared": Self.shared])
        let outcome = await ProjectFileReader(runner: fake, developerDir: nil, scratch: scratch)
            .read(.project(root + "/Phone.xcodeproj"))
        guard case .unsure(let reason) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reason.hasPrefix("could not read Packages/Acceptance/Package.swift (`swift package dump-package` exit 1"))
    }

    @Test func aSchemeFileThatIsNotXMLIsNotEnough() async throws {
        defer { cleanUp() }
        try makePhone()
        try write("<Scheme", to: "Phone.xcodeproj/xcshareddata/xcschemes/Broken.xcscheme")
        let outcome = await ProjectFileReader(runner: fake, developerDir: nil, scratch: scratch)
            .read(.project(root + "/Phone.xcodeproj"))
        #expect(outcome == .unsure("could not read Phone.xcodeproj/xcshareddata/xcschemes/Broken.xcscheme"))
    }

    @Test func aMissingProjectFileIsNotEnough() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(atPath: root + "/Empty.xcodeproj", withIntermediateDirectories: true)
        let outcome = await ProjectFileReader(runner: fake, developerDir: nil, scratch: scratch)
            .read(.project(root + "/Empty.xcodeproj"))
        #expect(outcome == .unsure("could not read Empty.xcodeproj/project.pbxproj"))
    }

    @Test func aWorkspaceReadsEachMemberProjectAndPackageFolder() async throws {
        defer { cleanUp() }
        try Fixture.copy("ProjectFiles/Suite", to: root)
        try write("", to: "Packages/Feature/Package.swift")
        stubPackages(["Feature": """
            {"name": "Feature", "products": [{"name": "Feature", "targets": ["Feature"], "type": {"library": ["automatic"]}}],
             "targets": [{"name": "Feature", "type": "regular", "dependencies": []},
                         {"name": "FeatureTests", "type": "test", "dependencies": [{"target": ["Feature", null]}]}]}
            """])
        let detected = try await detector().detect(root: root, container: "Suite.xcworkspace")
        // Everything builds both apps, so neither gets a scheme of its own; Helper does.
        #expect(detected == DetectedProject(
            container: "Suite.xcworkspace", kind: .workspace, schemes: ["Everything", "Feature", "Helper"],
            appSchemes: ["Everything"], testSchemes: ["Everything"],
            platforms: [.iOS, .visionOS, .macOS], deviceFamilies: [1, 2, 7]))
        #expect(xcodebuildCalls.isEmpty)
    }

    @Test func packageSchemesFollowXcodesRules() throws {
        let multi = try PackageLayout.parse(Data(Fixture.string("swift-package-dump-ios-watch.json").utf8))
        // A root package: its products, plus "<name>-Package" when there is more than one.
        #expect(multi.schemes(as: .root) == ["A", "B", "Multi Lib-Package"])
        let sample = try PackageLayout.parse(Data(Fixture.string("swift-package-dump.json").utf8))
        #expect(sample.schemes(as: .root) == ["SamplePackage"])                   // one product: named for the package
        let acceptance = try PackageLayout.parse(Data(Self.acceptance.utf8))
        #expect(acceptance.schemes(as: .packageReference) == [])
        #expect(acceptance.schemes(as: .folder) == ["victim", "AcceptanceTests"])
        let shared = try PackageLayout.parse(Data(Self.shared.utf8))
        #expect(shared.schemes(as: .packageReference) == ["Shared", "SharedTestSupport"])
        #expect(shared.schemes(as: .folder) == ["Shared", "SharedTestSupport"])  // SharedTests tests a product's target
    }
}
