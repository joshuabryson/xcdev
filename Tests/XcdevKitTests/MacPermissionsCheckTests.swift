import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd doctor`'s `mac-permissions`.
@Suite struct MacPermissionsCheckTests: DoctorFixture {
    let fake = FakeProcessRunner()

    @Test func itAppliesOnlyToProjectsWithAMacDevice() {
        #expect(MacPermissionsCheck.applies(devices: ["mac": DeviceSpec(platform: "macOS")]))
        #expect(!MacPermissionsCheck.applies(devices: ["iphone": DeviceSpec(type: "iPhone 18 Pro")]))
    }

    @Test func eachMissingGrantIsOneProblemWithTheSameNextAsTheCommand() {
        let both = MacPermissionsCheck.problems(MacPermissions(accessibility: false, screenRecording: false, hostApp: "iTerm"))
        #expect(both.count == 2 && both.allSatisfy { $0.check == "mac-permissions" && $0.action == nil })
        #expect(both[0].message == "iTerm has no Accessibility permission, so `xcd ui` cannot read a Mac app's windows")
        #expect(both[0].next == MacPermissions.accessibilityNext("iTerm"))     // the same words as the command's failure
        #expect(both[1].message.contains("Screen Recording") && both[1].next?.contains("quit and reopen") == true)
        #expect(MacPermissionsCheck.problems(MacPermissions(accessibility: true, screenRecording: true, hostApp: "iTerm")).isEmpty)
    }

    /// Doctor reads the grants through its environment, and lists the check only for a project with a Mac device.
    @Test func doctorReadsTheGrantsThroughItsEnvironmentAndOnlyForAMacProject() async throws {
        let (project, _, _, _) = try await setup(config: WorktreeServiceTests.config + "\n  mac: { platform: macOS }")
        defer { project.remove() }
        let off = FakeAccessibility(app: FakeApp(windows: []))
        off.setTrusted(false, capture: false)
        let service = DoctorService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                                    discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []),
                                    accessibility: { off }, hostApp: { "iTerm" })
        let report = await service.run(fix: false, checks: [MacPermissionsCheck()], from: project.root, includeDisk: false)
        #expect(report.problems.count == 2 && report.problems.allSatisfy { $0.action == nil && $0.scope == .mac })
        #expect(report.problems.first?.message.hasPrefix("iTerm has no Accessibility") == true)

        let (plain, _, _, _) = try await setup()
        defer { plain.remove() }
        let none = await service.run(fix: false, checks: [MacPermissionsCheck()], from: plain.root, includeDisk: false)
        #expect(none.checks.isEmpty && none.problems.isEmpty)
    }
}
