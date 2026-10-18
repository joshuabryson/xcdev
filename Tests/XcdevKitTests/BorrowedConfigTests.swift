import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// A checkout whose branch has no .xcdev.yml reads the main checkout's.
@Suite struct BorrowedConfigTests {
    static let config = """
    version: 1
    project: App.xcodeproj
    defaultDevice: iphone
    devices:
      iphone: { type: "iPhone 18 Pro" }
    hooks:
      pre-build: ./scripts/generate.sh
    """

    /// A worktree at `<base>/elsewhere/<folder>` on a new branch whose commit deleted .xcdev.yml.
    static func worktreeWithoutConfig(_ project: TempProject, folder: String = "old") throws -> String {
        let path = project.base + "/elsewhere/" + folder
        try TempProject.git(["worktree", "add", "-q", "-b", "old-" + folder, path], in: project.root)
        try TempProject.git(["rm", "-q", ".xcdev.yml"], in: path)
        try TempProject.git(["-c", "user.name=xcd", "-c", "user.email=xcd@example.com", "commit", "-q", "-m", "No config"], in: path)
        return Paths.canonical(path)
    }

    func service(_ project: TempProject) -> WorktreeService {
        WorktreeService(runner: RoutingRunner(fake: FakeProcessRunner()), globalPaths: GlobalPaths(base: project.home))
    }

    @Test func aBranchWithoutConfigUsesTheMainCheckoutsWithoutItsHooksAndSaysSo() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let path = try Self.worktreeWithoutConfig(project)
        let svc = service(project)
        let ctx = try await svc.open(from: path)
        #expect(ctx.config.project == "App.xcodeproj")
        #expect(ctx.config.hooks == nil)
        #expect(ctx.borrowedConfig == project.root + "/.xcdev.yml")
        #expect(svc.notes.all == ["this branch has no .xcdev.yml, so xcd uses the main checkout's (\(project.root)/.xcdev.yml); "
            + "its hooks don't run here until this branch has its own"])
    }

    @Test func theNoteLeavesOutHooksWhenTheMainCheckoutsConfigHasNone() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        let path = try Self.worktreeWithoutConfig(project)
        let svc = service(project)
        _ = try await svc.open(from: path)
        #expect(svc.notes.all == ["this branch has no .xcdev.yml, so xcd uses the main checkout's (\(project.root)/.xcdev.yml)"])
    }

    @Test func aBranchWithItsOwnConfigKeepsItsHooksAndHasNoNote() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let path = project.base + "/elsewhere/own"
        try TempProject.git(["worktree", "add", "-q", "-b", "own", path], in: project.root)
        let svc = service(project)
        let ctx = try await svc.open(from: path)
        #expect(ctx.config.hooks?.command(for: .preBuild) == "./scripts/generate.sh")
        #expect(ctx.borrowedConfig == nil)
        #expect(svc.notes.all.isEmpty)
    }

    @Test func aLocalFileInTheCheckoutStillOverridesTheBorrowedConfig() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let path = try Self.worktreeWithoutConfig(project)
        try "xcode: beta\n".write(toFile: path + "/.xcdev.local.yml", atomically: true, encoding: .utf8)
        #expect(try await service(project).open(from: path).config.xcode == "beta")
    }

    @Test func hooksOfWtCreateAndRemoveStillComeOnlyFromTheCheckoutsOwnFile() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let path = try Self.worktreeWithoutConfig(project)
        #expect(try service(project).hookConfig(worktree: path, projectRoot: project.root) == nil)
    }

    @Test func withNoConfigAnywhereTheFailureSaysToFollowTheSetupGuide() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let path = try Self.worktreeWithoutConfig(project)
        try FileManager.default.removeItem(atPath: project.root + "/.xcdev.yml")
        let inWorktree = await #expect(throws: XcdError.self) { try await service(project).open(from: path) }
        #expect(inWorktree?.code == .configMissing)
        #expect(inWorktree?.message == "no .xcdev.yml in this branch or in the main checkout (\(project.root))")
        #expect(inWorktree?.next == "this project isn't set up for xcd yet: follow `xcd guide setup`, which asks the user")
        let inMain = await #expect(throws: XcdError.self) { try await service(project).open(from: project.root) }
        #expect(inMain?.message == "no .xcdev.yml in \(project.root)")
        #expect(inMain?.next == inWorktree?.next)
    }

    @Test func projectCommandsAreFoundInTheBorrowedConfig() async throws {
        let project = try TempProject.make(config: Self.config + "\ncommands:\n  seed: { run: ./scripts/seed.sh }\n")
        defer { project.remove() }
        let path = try Self.worktreeWithoutConfig(project)
        let services = Services(runner: RoutingRunner(fake: FakeProcessRunner()), globalPaths: GlobalPaths(base: project.home),
                                currentDirectory: path, environment: [:])
        #expect(try await ExternalCommands(services: services).projectConfig()?.commands?["seed"] != nil)
    }

    @Test func anInvalidBorrowedConfigNamesTheMainCheckoutsFileAndSaysToAsk() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let path = try Self.worktreeWithoutConfig(project)
        try Self.config.replacingOccurrences(of: "version: 1", with: "version: 2")
            .write(toFile: project.root + "/.xcdev.yml", atomically: true, encoding: .utf8)
        let failure = await #expect(throws: XcdError.self) { try await service(project).open(from: path) }
        #expect(failure?.code == .configInvalid)
        #expect(failure?.details.contains("this branch has no .xcdev.yml, so xcd uses the main checkout's (\(project.root)/.xcdev.yml)") == true)
        #expect(failure?.next == "fix the file it names; the .xcdev.yml is the main checkout's (\(project.root)/.xcdev.yml), so ask the user before changing it")
    }

    @Test func anUnreadableBorrowedConfigIsAConfigErrorNotABug() async throws {
        let project = try TempProject.make(config: Self.config)
        defer { project.remove() }
        let path = try Self.worktreeWithoutConfig(project)
        try Data([0xFF, 0xFE, 0xFD]).write(to: URL(fileURLWithPath: project.root + "/.xcdev.yml"))
        let failure = await #expect(throws: XcdError.self) { try await service(project).open(from: path) }
        #expect(failure?.code == .configInvalid)
        #expect(failure?.message == "xcd could not read the main checkout's .xcdev.yml (\(project.root)/.xcdev.yml) as UTF-8 text")
    }
}
