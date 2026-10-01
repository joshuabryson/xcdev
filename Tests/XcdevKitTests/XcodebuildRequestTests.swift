import Foundation
import Testing
@testable import XcdevKit

@Suite struct XcodebuildRequestTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xcd req \(UUID().uuidString)").path

    func config(_ project: String, schemes: String = "") throws -> XcdevConfig {
        try ConfigLoader.parse(main: "version: 1\nproject: \(project)\n" + schemes)
    }

    func touch(_ relative: String, directory: Bool = false) throws {
        let path = root + "/" + relative
        if directory {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data())
        }
    }

    @Test func resolvesEachContainerKind() throws {
        defer { try? FileManager.default.removeItem(atPath: root) }
        try touch("App.xcworkspace", directory: true)
        try touch("App.xcodeproj", directory: true)
        try touch("Pkg/Package.swift")
        #expect(try ProjectContainer.resolve(config: config("App.xcworkspace"), worktreeRoot: root) == .workspace(root + "/App.xcworkspace"))
        #expect(try ProjectContainer.resolve(config: config("App.xcodeproj"), worktreeRoot: root) == .project(root + "/App.xcodeproj"))
        let package = try ProjectContainer.resolve(config: config("Pkg/Package.swift"), worktreeRoot: root)
        #expect(package == .package(directory: root + "/Pkg"))
        #expect(package.arguments.isEmpty && package.isPackage && package.workingDirectory == root + "/Pkg")
    }

    @Test func missingOrWrongProjectIsAConfigError() throws {
        defer { try? FileManager.default.removeItem(atPath: root) }
        let missing = #expect(throws: XcdError.self) {
            try ProjectContainer.resolve(config: config("Nope.xcodeproj"), worktreeRoot: root)
        }
        #expect(missing?.code == .configInvalid)
        #expect(missing?.message == "project: Nope.xcodeproj does not exist in \(root)")
        try touch("README.md")
        let wrong = #expect(throws: XcdError.self) {
            try ProjectContainer.resolve(config: config("README.md"), worktreeRoot: root)
        }
        #expect(wrong?.message == "project: README.md is not a .xcworkspace, .xcodeproj, or Package.swift")
    }

    @Test func argumentsKeepPathsWithSpacesWholeAndUseWorktreeState() {
        let paths = WorktreePaths(root: "/w/My App")
        let request = XcodebuildRequest(actions: [.clean, .build], container: .project("/w/My App/App.xcodeproj"),
                                        scheme: "App", destination: .simulator(udid: "U1"), configuration: "Release",
                                        paths: paths, resultBundle: "/w/My App/.xcdev/results/r.xcresult")
        #expect(request.arguments == [
            "clean", "build", "-project", "/w/My App/App.xcodeproj", "-scheme", "App", "-configuration", "Release",
            "-destination", "id=U1", "-derivedDataPath", "/w/My App/.xcdev/DerivedData",
            "-clonedSourcePackagesDirPath", "/w/My App/.xcdev/SourcePackages",
            "-resultBundlePath", "/w/My App/.xcdev/results/r.xcresult", "-IDEBuildingContinueBuildingAfterErrors=YES",
        ])
        let inv = request.invocation(developerDir: "/X.app/Contents/Developer", logFile: "/w/My App/.xcdev/logs/b.log",
                                     timeout: .seconds(1800))
        #expect(inv.argv.prefix(2) == ["xcrun", "xcodebuild"])
        #expect(inv.environment["DEVELOPER_DIR"] == "/X.app/Contents/Developer")
        #expect(inv.outputFile == "/w/My App/.xcdev/logs/b.log")
        #expect(inv.workingDirectory == "/w/My App")
        #expect(inv.timeout == .seconds(1800))
    }

    @Test func testFiltersAndPackageHost() {
        let request = XcodebuildRequest(actions: [.test], container: .package(directory: "/p"), scheme: "Pkg",
                                        destination: .macOS, paths: WorktreePaths(root: "/p"),
                                        onlyTesting: ["PkgTests/works()"], skipTesting: ["PkgTests/Slow"])
        #expect(request.arguments == [
            "test", "-scheme", "Pkg", "-destination", "platform=macOS", "-derivedDataPath", "/p/.xcdev/DerivedData",
            "-clonedSourcePackagesDirPath", "/p/.xcdev/SourcePackages", "-only-testing:PkgTests/works()",
            "-skip-testing:PkgTests/Slow", "-IDEBuildingContinueBuildingAfterErrors=YES",
        ])
        let settings = request.buildSettingsInvocation(developerDir: nil)
        #expect(settings.arguments == [
            "xcodebuild", "-showBuildSettings", "-json", "-scheme", "Pkg", "-destination", "platform=macOS",
            "-derivedDataPath", "/p/.xcdev/DerivedData", "-clonedSourcePackagesDirPath", "/p/.xcdev/SourcePackages",
        ])
        #expect(settings.workingDirectory == "/p")
    }

    @Test func cleanHasNoContinueFlag() {
        let request = XcodebuildRequest(actions: [.clean], container: .project("/p/A.xcodeproj"), scheme: "A",
                                        paths: WorktreePaths(root: "/p"))
        #expect(!request.arguments.contains("-IDEBuildingContinueBuildingAfterErrors=YES"))
    }

    @Test func schemeRoles() throws {
        let both = try config("A.xcodeproj", schemes: "schemes: { app: App, test: AppTests }")
        let appOnly = try config("A.xcodeproj", schemes: "schemes: { app: App }")
        let none = try config("A.xcodeproj")
        #expect(Schemes.configured(nil, role: .app, config: both) == "App")
        #expect(Schemes.configured(nil, role: .test, config: both) == "AppTests")
        #expect(Schemes.configured(nil, role: .test, config: appOnly) == "App")
        #expect(Schemes.configured("test", role: .app, config: both) == "AppTests")
        #expect(Schemes.configured("Other", role: .app, config: both) == "Other")
        #expect(Schemes.configured(nil, role: .app, config: none) == nil)
    }

    @Test func parsesRecordedLists() {
        #expect(Schemes.parseList(Data(Fixture.string("xcodebuild-list-project.json").utf8)) == ["SampleApp"])
        #expect(Schemes.parseList(Data(Fixture.string("xcodebuild-list-package.json").utf8)) == ["SamplePackage"])
        #expect(Schemes.parseList(Data("not json".utf8)).isEmpty)
        let list = Schemes.listInvocation(.project("/p/A.xcodeproj"), paths: WorktreePaths(root: "/p"), developerDir: nil)
        // Xcode 27 rejects -list with -derivedDataPath ("-scheme … is required"), so only packages are redirected.
        #expect(list.arguments == ["xcodebuild", "-list", "-json", "-project", "/p/A.xcodeproj",
                              "-clonedSourcePackagesDirPath", "/p/.xcdev/SourcePackages"])
    }

    @Test func missingSchemeListsWhatExists() {
        let error = Schemes.missing(role: .test, available: ["App", "AppTests"])
        #expect(error.code == .usage)
        #expect(error.message == "no test scheme is configured")
        #expect(error.next == "set schemes.test in .xcdev.yml to one of: App, AppTests (or pass --scheme)")
    }
}
