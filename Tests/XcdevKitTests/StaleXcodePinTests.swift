import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// A worktree's pinned Xcode once it no longer stands for `xcode:`: the Xcode at its path was updated in place (Xcodes.app
/// does that), or, with no `xcode:`, xcode-select now points to another Xcode. The next command pins again, and
/// `xcd doctor` reports it with the fix.
@Suite struct StaleXcodePinTests: DoctorFixture {
    let fake = FakeProcessRunner()
    let apps = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-pin-\(UUID().uuidString)").path

    var discovery: XcodeDiscovery { XcodeDiscovery(runner: fake, applicationsDirectories: [apps]) }
    /// What the worktree pinned before the update.
    var old: XcodeInstall { XcodeInstall(path: apps + "/Xcode.app", version: "27.1", build: "27A9275") }

    /// Installs fake Xcodes ("Xcode.app": ("27.2", "27B52")) under `apps`, points xcode-select at `selected`, and
    /// answers plutil from the fakes' version.plist as the real one would.
    func install(_ xcodes: [String: (version: String, build: String)], selected: String) throws {
        for (name, xcode) in xcodes {
            try XcodeTests.makeFakeXcode(at: apps + "/" + name, version: xcode.version, build: xcode.build)
        }
        fake.stub(["mdfind"], stdout: "")
        fake.stub(["xcode-select", "-p"], stdout: selected.hasPrefix("/") ? selected + "\n" : apps + "/" + selected + "/Contents/Developer\n")
        fake.stub(["plutil", "-convert", "json"]) { invocation in
            guard let plist = NSDictionary(contentsOfFile: invocation.argv.last ?? "") else {
                return ProcessOutput(exitCode: 1, stderr: "file does not exist or is not readable")
            }
            return ProcessOutput(stdout: String(decoding: try JSONSerialization.data(withJSONObject: plist), as: UTF8.self))
        }
    }

    func context(xcode spec: String? = nil) throws -> WorktreeContext {
        let yaml = "version: 1\nproject: App.xcodeproj\n" + (spec.map { "xcode: \"\($0)\"\n" } ?? "")
            + "devices:\n  iphone: { type: \"iPhone 18 Pro\" }\n"
        let state = WorktreeState(id: "id", name: "main", project: "App", projectRoot: apps, path: apps, branch: "main",
                                  xcode: old, devices: [:], status: .ready, createdAt: Date())
        return WorktreeContext(location: ProjectLocation(projectRoot: apps, worktreeRoot: apps),
                               config: try ConfigLoader.parse(main: yaml), state: state)
    }

    var provisioner: DeviceProvisioner {
        DeviceProvisioner(runner: fake, globalPaths: GlobalPaths(base: apps + "/home"), discovery: discovery)
    }

    var plutilCalls: Int { fake.calls.filter { $0.argv.first == "plutil" }.count }

    // MARK: When a pin is stale

    @Test func anXcodeUpdatedInPlaceIsStaleWhateverTheSpec() async throws {
        defer { try? FileManager.default.removeItem(atPath: apps) }
        try install(["Xcode.app": ("27.2", "27B52")], selected: "Xcode.app")
        for spec in [nil, "system", "27", "latest", apps + "/Xcode.app"] {
            #expect(await discovery.staleness(of: old, spec: spec) == "\(apps)/Xcode.app is now Xcode 27.2 (27B52)", "\(spec ?? "no xcode:")")
        }
    }

    @Test func withNoXcodeKeyAPinFollowsXcodeSelect() async throws {
        defer { try? FileManager.default.removeItem(atPath: apps) }
        try install(["Xcode.app": ("27.1", "27A9275"), "Xcode-beta.app": ("27.3", "27C5")], selected: "Xcode-beta.app")
        #expect(await discovery.staleness(of: old, spec: nil) == "xcode-select points to \(apps)/Xcode-beta.app")
        #expect(await discovery.staleness(of: old, spec: " System ") == "xcode-select points to \(apps)/Xcode-beta.app")
        // A named Xcode is the worktree's whatever xcode-select says.
        #expect(await discovery.staleness(of: old, spec: "27.1") == nil)
        #expect(await discovery.staleness(of: old, spec: "latest") == nil)
    }

    @Test func aPinStandsWhileItsXcodeIsUnchangedAndSelected() async throws {
        defer { try? FileManager.default.removeItem(atPath: apps) }
        try install(["Xcode.app": ("27.1", "27A9275")], selected: "Xcode.app")
        #expect(await discovery.staleness(of: old, spec: nil) == nil)
    }

    /// Command Line Tools are not an Xcode, so "system" resolved to the newest stable Xcode when the pin was made.
    @Test func commandLineToolsSelectedLeavesThePinAlone() async throws {
        defer { try? FileManager.default.removeItem(atPath: apps) }
        try install(["Xcode.app": ("27.1", "27A9275")], selected: "/Library/Developer/CommandLineTools")
        #expect(await discovery.staleness(of: old, spec: nil) == nil)
    }

    /// A pin xcd cannot check (plutil and xcode-select both fail) is kept: an unreadable install is no reason to move.
    @Test func aPinXcdCannotCheckIsKept() async {
        #expect(await discovery.staleness(of: old, spec: nil) == nil)
    }

    // MARK: The next command pins again

    @Test func theNextCommandPinsTheXcodeNowAtThePath() async throws {
        defer { try? FileManager.default.removeItem(atPath: apps) }
        try install(["Xcode.app": ("27.2", "27B52")], selected: "Xcode.app")
        var ctx = try context()
        let updated = XcodeInstall(path: apps + "/Xcode.app", version: "27.2", build: "27B52")
        #expect(try await provisioner.ensureXcode(&ctx) == updated)
        #expect(try WorktreeStateStore.load(ctx.paths)?.xcode == updated)
        #expect(try await provisioner.ensureXcode(&ctx) == updated)
        #expect(plutilCalls == 1)                                          // checked once per command
    }

    @Test func withNoXcodeKeyTheNextCommandPinsXcodeSelectsXcode() async throws {
        defer { try? FileManager.default.removeItem(atPath: apps) }
        try install(["Xcode.app": ("27.1", "27A9275"), "Xcode-beta.app": ("27.3", "27C5")], selected: "Xcode-beta.app")
        var ctx = try context()
        #expect(try await provisioner.ensureXcode(&ctx).path == apps + "/Xcode-beta.app")
        #expect(try WorktreeStateStore.load(ctx.paths)?.xcode?.build == "27C5")
    }

    @Test func aPinThatStandsIsKeptAndCheckedOncePerCommand() async throws {
        defer { try? FileManager.default.removeItem(atPath: apps) }
        try install(["Xcode.app": ("27.1", "27A9275"), "Xcode-beta.app": ("27.3", "27C5")], selected: "Xcode-beta.app")
        var ctx = try context(xcode: "27.1")
        #expect(try await provisioner.ensureXcode(&ctx) == old)
        #expect(try await provisioner.ensureXcode(&ctx) == old)
        #expect(plutilCalls == 1)
        #expect(!fake.calls.contains { $0.argv.first == "mdfind" })      // nothing was resolved again
    }

    // MARK: Doctor

    @Test func doctorReportsAnXcodeUpdatedInPlaceAndUnpinsIt() async throws {
        defer { try? FileManager.default.removeItem(atPath: apps) }
        try install(["Xcode.app": ("27.2", "27B52")], selected: "Xcode.app")
        var (project, _, _, main) = try await setup()
        defer { project.remove() }
        main.state.xcode = old
        try WorktreeStateStore.save(main.state, main.paths)

        let report = await doctor(project, discovery: discovery).run(fix: false, checks: [ProjectCheck()], from: project.root)
        let pinned = try #require(report.problems.first { $0.action == .unpinXcode })
        #expect(pinned.message == "worktree 'main' is pinned to \(old.summary), but \(apps)/Xcode.app is now Xcode 27.2 (27B52)")
        #expect(pinned.fix == "unpin it, so the next command resolves `xcode:` again")
        #expect(try WorktreeStateStore.load(main.paths)?.xcode == old)      // reported only, without --fix

        _ = await doctor(project, discovery: discovery).run(fix: true, checks: [ProjectCheck()], from: project.root)
        #expect(try WorktreeStateStore.load(main.paths)?.xcode == nil)
    }

    /// Re-pinned between detect and fix (another command ran), the worktree keeps its new pin.
    @Test func aWorktreeRepinnedMeanwhileKeepsItsNewPin() async throws {
        defer { try? FileManager.default.removeItem(atPath: apps) }
        try install(["Xcode.app": ("27.2", "27B52")], selected: "Xcode.app")
        var (project, _, _, main) = try await setup()
        defer { project.remove() }
        main.state.xcode = old
        try WorktreeStateStore.save(main.state, main.paths)
        let env = await doctor(project, discovery: discovery).environment(from: project.root, fixing: true)
        let problem = try #require(await ProjectCheck().detect(env).first { $0.action == .unpinXcode })

        let updated = XcodeInstall(path: apps + "/Xcode.app", version: "27.2", build: "27B52")
        main.state.xcode = updated
        try WorktreeStateStore.save(main.state, main.paths)
        await #expect(throws: DoctorLeftAlone.self) { try await ProjectCheck().fix(problem, env) }
        #expect(try WorktreeStateStore.load(main.paths)?.xcode == updated)
    }
}
