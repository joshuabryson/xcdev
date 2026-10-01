import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"

@Suite(.enabled(if: enabled, "set XCD_INTEGRATION=1 to run (needs Xcode + simulators)"), .serialized)
struct WorktreeSimulatorIntegrationTests {
    let runner = SystemProcessRunner()

    @Test func discoversARealXcode() async throws {
        let xcode = try await XcodeDiscovery(runner: runner).resolve(spec: nil)
        #expect(FileManager.default.fileExists(atPath: xcode.developerDir))
    }

    @Test func parallelWorktreesGetIsolatedClonesAndCleanUp() async throws {
        let simctl = SimctlClient(runner: runner, developerDir: nil)
        let catalog = try await simctl.catalog()
        let phone = try #require(catalog.deviceTypes.first { type in
            type.productFamily == "iPhone"
                && catalog.runtimes.contains { $0.isAvailable && $0.platform == "iOS" && $0.supports(type) }
        }, "no iPhone simulator runtime installed")

        let project = try TempProject.make(config: """
        version: 1
        project: App.xcodeproj
        defaultDevice: iphone
        devices:
          iphone: { type: "\(phone.name)" }
        """, name: "xcd it \(UUID().uuidString.prefix(6))")
        defer { project.remove() }

        let services = Services(runner: runner, globalPaths: GlobalPaths(base: project.home),
                                currentDirectory: project.root, environment: [:])
        let main = try await services.open(worktree: nil)
        let a = try await services.worktrees.create(name: "agent-a", in: main).state
        let b = try await services.worktrees.create(name: "agent-b", in: main).state

        @Sendable func provision(_ path: String) async throws -> ProvisionedDevice {
            var ctx = try await services.worktrees.open(from: path)
            return try await services.provisioner.ensure("iphone", in: &ctx)
        }
        async let deviceA = provision(a.path)
        async let deviceB = provision(b.path)
        let (cloneA, cloneB) = try await (deviceA, deviceB)
        #expect(cloneA.udid != cloneB.udid)

        let after = try await simctl.catalog()
        let templateName = "xcd-template · \(cloneA.deviceType) · \(cloneA.runtime)"
        #expect(after.devices.filter { $0.name == templateName }.count == 1)
        #expect(after.device(udid: cloneA.udid)?.name == "xcd · \(main.state.project) · agent-a · iphone")

        var ctxA = try await services.worktrees.open(from: a.path)
        _ = try await services.provisioner.boot("iphone", in: &ctxA)
        #expect(try await simctl.catalog().device(udid: cloneA.udid)?.state == "Booted")
        #expect(try await simctl.catalog().device(udid: cloneB.udid)?.state == "Shutdown")

        _ = try await services.worktrees.remove(name: "agent-a", in: main)
        _ = try await services.worktrees.remove(name: "agent-b", in: main)
        let final = try await simctl.catalog()
        #expect(final.device(udid: cloneA.udid) == nil)
        #expect(final.device(udid: cloneB.udid) == nil)
        #expect(try services.worktrees.list(projectRoot: project.root).map(\.name) == ["main"])
    }
}
