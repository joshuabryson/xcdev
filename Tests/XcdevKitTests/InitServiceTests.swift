import Foundation
import Synchronization
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct InitServiceTests {
    let fake = FakeProcessRunner()

    /// A git repo holding `projects` (empty .xcodeproj folders) and no .xcdev.yml, with xcodebuild and simctl
    /// answering from the recorded iOS + watch app.
    func setup(projects: [String] = ["SampleApp.xcodeproj"], progress: Activity = .silent,
               now: @escaping @Sendable () -> Date = { Date() }) throws -> (TempProject, InitService) {
        let project = try TempProject.make(config: "version: 1\nproject: x\n")
        try FileManager.default.removeItem(atPath: project.root + "/.xcdev.yml")
        try TempProject.git(["-c", "user.name=xcd", "-c", "user.email=xcd@example.com", "commit", "-qam", "Remove config"], in: project.root)
        for container in projects { try project.write("", to: container + "/project.pbxproj") }
        fake.stub(["mdfind"], stdout: "")
        fake.stub(["xcode-select"], exitCode: 2)
        fake.stub(["xcrun", "xcodebuild", "-list"]) { inv in
            try Self.writeState(inv)
            return ProcessOutput(stdout: Fixture.string("xcodebuild-list-watch.json"))
        }
        fake.stub(["xcrun", "xcodebuild", "-showBuildSettings"]) { inv in
            let scheme = inv.arguments[inv.arguments.firstIndex(of: "-scheme")! + 1]
            return ProcessOutput(stdout: Fixture.string(scheme == "SampleApp" ? "build-settings-scheme-app.json"
                                                                                : "build-settings-scheme-watch.json"))
        }
        fake.stub(["xcrun", "simctl", "list", "-j"], stdout: Fixture.string("simctl-list-init.json"))
        let runner = RoutingRunner(fake: fake, realExecutables: ["git"])
        let service = InitService(runner: runner, globalPaths: GlobalPaths(base: project.home),
                                  discovery: XcodeDiscovery(runner: runner, applicationsDirectories: []),
                                  progress: progress, now: now)
        return (project, service)
    }

    /// Like real xcodebuild, leaves package state in the folder `-clonedSourcePackagesDirPath` names (the package cache).
    static func writeState(_ invocation: Invocation) throws {
        let packages = invocation.arguments[invocation.arguments.firstIndex(of: "-clonedSourcePackagesDirPath")! + 1]
        try FileManager.default.createDirectory(atPath: packages, withIntermediateDirectories: true)
        try "".write(toFile: packages + "/workspace-state.json", atomically: true, encoding: .utf8)
    }

    func files(_ root: String) throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: root).filter { !$0.hasPrefix(".git/") }.sorted()
    }

    /// Scratch folders `init` left in the cache directory.
    func leftoverScratch(_ project: TempProject) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: project.home + "/cache")) ?? []).filter { $0.hasPrefix("init-") }
    }

    @Test func planDetectsAndWritesNothing() async throws {
        let (project, service) = try setup()
        defer { project.remove() }
        let before = try files(project.root)
        let report = try await service.plan(from: project.root + "/SampleApp.xcodeproj")
        #expect(report.decisions.map(\.key) == ["devices.default", "devices.ipad", "devices.watch"])
        #expect(report.xcode == "none found (install Xcode from https://developer.apple.com/xcode/)")
        #expect(!report.configExists)
        #expect(try files(project.root) == before)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: project.root + "/.xcdev") && !fm.fileExists(atPath: project.root + "/.xcdev.yml"))
        #expect(!fm.fileExists(atPath: project.root + "/.build"))
        #expect(fake.commandLines.contains { $0.contains("-list") })          // detection wrote to the scratch folder…
        #expect(leftoverScratch(project).isEmpty)                             // …which is gone
    }

    /// The `-clonedSourcePackagesDirPath` and `-derivedDataPath` of each xcodebuild call so far.
    func xcodebuildPaths() -> (packages: Set<String>, derivedData: Set<String>) {
        func values(_ flag: String) -> Set<String> {
            Set(fake.calls.compactMap { call in call.arguments.firstIndex(of: flag).map { call.arguments[$0 + 1] } })
        }
        return (values("-clonedSourcePackagesDirPath"), values("-derivedDataPath"))
    }

    @Test func packagesAreKeptInAPerProjectCacheThatLaterRunsReuse() async throws {
        let (project, service) = try setup()
        defer { project.remove() }
        _ = try await service.plan(from: project.root)
        _ = try await service.write(answers: [:], force: false, from: project.root)
        let paths = xcodebuildPaths()
        let cache = GlobalPaths(base: project.home).cacheDirectory
        let packages = try #require(paths.packages.first)
        #expect(paths.packages.count == 1)                                   // -list and -showBuildSettings, both runs
        #expect(packages == cache + "/packages/" + PackageCache.key(for: project.root) + "/SourcePackages")
        #expect(FileManager.default.fileExists(atPath: packages + "/workspace-state.json"))       // kept…
        #expect(paths.derivedData.count == 2 && paths.derivedData.allSatisfy { $0.hasPrefix(cache + "/init-") })
        #expect(leftoverScratch(project).isEmpty)                            // …while the scratch DerivedData is not
        #expect(!FileManager.default.fileExists(atPath: project.root + "/.xcdev"))
    }

    @Test func packageCacheKeysAreReadableStableAndPerRoot() {
        let key = PackageCache.key(for: "/Users/me/Developer/My App")
        #expect(key == PackageCache.key(for: "/Users/me/Developer/My App"))
        #expect(key.hasPrefix("My-App-") && key.count == "My-App-".count + 16)
        #expect(key.dropFirst("My-App-".count).allSatisfy { $0.isHexDigit })
        #expect(PackageCache.key(for: "/Users/me/Other/My App") != key)
        #expect(PackageCache.key(for: "/").count == 16)                       // no readable name, just the hash
    }

    @Test func theCacheIsLockedWhileXcodebuildUsesIt() async throws {
        let (project, service) = try setup()
        defer { project.remove() }
        let cache = PackageCache(globalPaths: GlobalPaths(base: project.home), root: project.root)
        let heldDuringList = Counter()
        fake.stub(["xcrun", "xcodebuild", "-list"]) { inv in
            try Self.writeState(inv)
            if FileLock.isHeld(at: cache.lockPath) { heldDuringList.increment() }
            return ProcessOutput(stdout: Fixture.string("xcodebuild-list-watch.json"))
        }
        _ = try await service.plan(from: project.root)
        #expect(heldDuringList.value == 1)
        #expect(cache.lockPath == GlobalPaths(base: project.home).cacheDirectory + "/packages/" + PackageCache.key(for: project.root) + ".lock")
        #expect(!FileLock.isHeld(at: cache.lockPath))
    }

    @Test func listingGetsTenMinutesAndATimeoutSaysItWasResolvingPackages() async throws {
        let (project, service) = try setup()
        defer { project.remove() }
        _ = try await service.plan(from: project.root)
        #expect(fake.calls.first { $0.arguments.contains("-list") }?.timeout == .seconds(600))
        fake.stub(["xcrun", "xcodebuild", "-list"]) { _ in
            throw XcdError(.timeout, "`xcrun xcodebuild -list` timed out after 600.0 seconds", next: "re-run with a larger --timeout")
        }
        let error = await #expect(throws: XcdError.self) { try await service.plan(from: project.root) }
        #expect(error?.code == .timeout)
        #expect(error?.next?.hasPrefix("it was resolving the Swift packages of SampleApp.xcodeproj") == true)
        #expect(leftoverScratch(project).isEmpty)
    }

    @Test func initReportsEachLongStep() async throws {
        let lines = Mutex<[String]>([])
        let (project, service) = try setup(progress: .plain { line in lines.withLock { $0.append(line) } })
        defer { project.remove() }
        _ = try await service.plan(from: project.root)
        #expect(lines.withLock { $0 } == [
            "listing the schemes of SampleApp.xcodeproj and resolving any Swift packages (the first run can take a minute)…",
            "reading the build settings of 2 schemes…"])
    }

    @Test func staleScratchFoldersAreDeletedWhenInitStarts() async throws {
        let now = Date()
        let (project, service) = try setup(now: { now })
        defer { project.remove() }
        let cache = GlobalPaths(base: project.home).cacheDirectory
        let fm = FileManager.default
        func folder(_ name: String, age: TimeInterval) throws -> String {
            let path = cache + "/" + name
            try fm.createDirectory(atPath: path + "/.xcdev/DerivedData", withIntermediateDirectories: true)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: path)
            return path
        }
        let stale = try folder("init-" + UUID().uuidString, age: 2 * 3600)
        let recent = try folder("init-" + UUID().uuidString, age: 50 * 60)
        let notOurs = try folder("init-backup", age: 5 * 3600)
        let packages = try folder("packages", age: 5 * 3600)
        _ = try await service.plan(from: project.root)
        #expect(!fm.fileExists(atPath: stale))
        #expect(fm.fileExists(atPath: recent) && fm.fileExists(atPath: notOurs) && fm.fileExists(atPath: packages))

        let again = try folder("init-" + UUID().uuidString, age: 3 * 3600)
        _ = try await service.write(answers: [:], force: false, from: project.root)
        #expect(!fm.fileExists(atPath: again))
    }

    @Test func theScratchFolderIsDeletedWhenDetectionFails() async throws {
        let (project, service) = try setup()
        defer { project.remove() }
        fake.stub(["xcrun", "xcodebuild", "-list"]) { inv in
            try Self.writeState(inv)
            return ProcessOutput(exitCode: 74, stdout: "", stderr: "xcodebuild: error: The project is damaged.\n")
        }
        await #expect(throws: XcdError.self) { try await service.plan(from: project.root) }
        #expect(fake.commandLines.contains { $0.contains("-list") })
        #expect(leftoverScratch(project).isEmpty)
    }

    @Test func writeAppliesAnswersAndIgnoresTheStateFolders() async throws {
        let (project, service) = try setup()
        defer { project.remove() }
        try project.write("build/\n.xcdev\n", to: ".gitignore")
        let report = try await service.write(answers: ["devices.watch": "none"], force: false, from: project.root)
        #expect(report.status == .written && report.path == project.root + "/.xcdev.yml")
        #expect(report.gitignoreAdded == [".xcdev.local.yml"])
        #expect(try String(contentsOfFile: project.root + "/.gitignore", encoding: .utf8)
                == "build/\n.xcdev\n# xcdev: per-worktree build state and per-machine overrides\n.xcdev.local.yml\n")
        let config = try ConfigLoader.load(worktreeRoot: project.root, projectRoot: project.root)
        #expect(config.project == "SampleApp.xcodeproj" && config.defaultDevice == "iphone")
        #expect(config.allDevices.keys.sorted() == ["iphone"])
        #expect(report.text.hasSuffix("next: run `xcd config show` to check the result, then `xcd doctor`"))
        #expect(leftoverScratch(project).isEmpty)
    }

    @Test func anExistingConfigIsKeptUnlessForced() async throws {
        let (project, service) = try setup()
        defer { project.remove() }
        _ = try await service.write(answers: [:], force: false, from: project.root)
        let written = try String(contentsOfFile: project.root + "/.xcdev.yml", encoding: .utf8)

        let again = try await service.write(answers: [:], force: false, from: project.root)
        #expect(again.status == .unchanged)
        #expect(again.text.hasPrefix(".xcdev.yml already exists, so nothing changed"))
        let answered = await #expect(throws: XcdError.self) {
            try await service.write(answers: ["xcode": "system"], force: false, from: project.root)
        }
        #expect(answered?.code == .usage)
        #expect(try String(contentsOfFile: project.root + "/.xcdev.yml", encoding: .utf8) == written)

        let forced = try await service.write(answers: ["devices.default": "iPhone 17 Pro"], force: true, from: project.root)
        #expect(forced.status == .written)
        #expect(try ConfigLoader.load(worktreeRoot: project.root, projectRoot: project.root).allDevices["iphone"]?.type == "iPhone 17 Pro")
    }

    @Test func theProjectAnswerPicksAmongSeveral() async throws {
        let (project, service) = try setup(projects: ["Admin.xcodeproj", "SampleApp.xcodeproj"])
        defer { project.remove() }
        let plan = try await service.plan(from: project.root)
        #expect(plan.decisions.first?.key == "project")
        _ = try await service.write(answers: ["project": "SampleApp.xcodeproj"], force: false, from: project.root)
        #expect(try ConfigLoader.load(worktreeRoot: project.root, projectRoot: project.root).project == "SampleApp.xcodeproj")
        let error = await #expect(throws: XcdError.self) {
            try await service.write(answers: ["project": "Nope.xcodeproj"], force: true, from: project.root)
        }
        #expect(error?.code == .configInvalid)
        #expect(error?.next == "use one of: Admin.xcodeproj, SampleApp.xcodeproj")
    }

    @Test func noProjectIsNotInProject() async throws {
        let (project, service) = try setup(projects: [])
        defer { project.remove() }
        let error = await #expect(throws: XcdError.self) { try await service.plan(from: project.root) }
        #expect(error?.code == .notInProject)
    }

    @Test func setAnswersParse() throws {
        #expect(try InitAnswers.parse(["devices.default=iPhone 17 Pro", "xcode=system", "xcode=27.0"])
                == ["devices.default": "iPhone 17 Pro", "xcode": "27.0"])
        let error = #expect(throws: XcdError.self) { try InitAnswers.parse(["xcode"]) }
        #expect(error?.message == "--set xcode is not KEY=VALUE")
        #expect(error?.next == "pass answers like `--set devices.default=\"iPhone 17 Pro\" xcode=system`")
    }
}
