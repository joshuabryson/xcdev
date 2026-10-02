import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct InitServiceTests {
    let fake = FakeProcessRunner()

    /// A git repo holding `projects` (empty .xcodeproj folders) and no .xcdev.yml, with xcodebuild and simctl
    /// answering from the recorded iOS + watch app.
    func setup(projects: [String] = ["SampleApp.xcodeproj"]) throws -> (TempProject, InitService) {
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
                                  discovery: XcodeDiscovery(runner: runner, applicationsDirectories: []))
        return (project, service)
    }

    /// Like real xcodebuild, leaves package state in the folder `-clonedSourcePackagesDirPath` names (the scratch folder).
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
        #expect(report.text.hasSuffix("next: run `xcd config show` to check the result"))
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
