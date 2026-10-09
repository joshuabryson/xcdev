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
    deeplinks:
      routes:
        item: { description: "One item", url: "myapp://item?id={id}", params: { id: {} } }
        settings/about: { description: "About", url: "myapp://settings/about" }
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

    /// `xcd open` takes a route name first. What follows it is the route's parameters, which are not completed.
    @Test func offersRouteNamesForTheFirstArgumentOfOpen() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let completions = completions(project)
        #expect(await completions.routes(["xcd", "open", ""], at: 2) == ["item", "settings/about"])
        #expect(await completions.routes(["xcd", "open", "se"], at: 2) == ["item", "settings/about"])      // the shell narrows them
        // Options and their values before the route are passed over.
        #expect(await completions.routes(["xcd", "open", "--cold", "--device", "iphone", "--preset=onboarding", ""], at: 6)
                == ["item", "settings/about"])
        #expect(await completions.routes(["xcd", "open", "item", ""], at: 3).isEmpty)                     // a parameter
        #expect(await completions.routes(["xcd", "open", "--dry-run", "item", "id=1", ""], at: 5).isEmpty)
        #expect(await completions.routes(["xcd", "open", "--device", ""], at: 3).isEmpty)                 // an option's value
        #expect(await completions.routes(["xcd", "open"], at: 2) == ["item", "settings/about"])           // nothing typed yet
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
        #expect(await completions(project).routes(["xcd", "open", ""], at: 2).isEmpty)
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
