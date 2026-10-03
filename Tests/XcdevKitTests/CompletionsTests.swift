import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct CompletionsTests {
    static let config = """
    version: 1
    project: App.xcodeproj
    schemes: { app: App, test: AppTests }
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro" }
      mac: { platform: macOS }
    presets:
      onboarding: { args: [-resetOnboarding, "YES"] }
    """

    func completions(_ project: TempProject, from directory: String? = nil) -> Completions {
        Completions(runner: SystemProcessRunner(), globalPaths: GlobalPaths(base: project.home),
                    currentDirectory: directory ?? project.root)
    }

    @Test func offersNamesFromTheConfig() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        try project.write("", to: "Sources/a.swift")
        let completions = completions(project, from: project.root + "/Sources")
        #expect(await completions.devices() == ["iphone", "mac"])
        #expect(await completions.schemes() == ["app", "test", "App", "AppTests"])
        #expect(await completions.presets() == ["onboarding"])
    }

    @Test func includesTheLocalConfig() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        try project.write("devices:\n  ipad: { type: \"iPad Pro\" }\n", to: ConfigLoader.localFileName)
        #expect(await completions(project).devices() == ["ipad", "iphone", "mac"])
    }

    @Test func offersNothingOutsideAProjectOrWithABrokenConfig() async throws {
        let project = try TempProject.make(config: "version: 1\nproject: [")
        defer { project.remove() }
        #expect(await completions(project).devices().isEmpty)
        #expect(await completions(project, from: project.base).presets().isEmpty)
    }

    @Test func offersThisProjectsWorktrees() async throws {
        let project = try TempProject.make(config: Self.config)
        let other = try TempProject.make(config: Self.config, name: "Other")
        defer { project.remove(); other.remove() }
        let registry = Registry(paths: GlobalPaths(base: project.home))
        for (root, name) in [(project.root, "feat"), (project.root, "main"), (other.root, "elsewhere")] {
            let state = WorktreeState(id: UUID().uuidString, name: name, project: "App", projectRoot: root,
                                      path: root + "/" + name, branch: name, xcode: nil, devices: [:], status: .ready,
                                      createdAt: Date())
            try await registry.upsert(RegistryEntry(state))
        }
        #expect(await completions(project).worktrees() == ["feat", "main"])
    }

    @Test func staticValues() {
        #expect(Completions.guideTopics == Guides.all.map(\.topic))
        #expect(Completions.configKeys.contains("devices.<name>.runtime"))
        #expect(Completions.configKeys.contains("schemes.app"))
    }
}
