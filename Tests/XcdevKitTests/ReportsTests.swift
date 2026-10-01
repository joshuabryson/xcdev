import Foundation
import Testing
@testable import XcdevKit

@Suite struct ReportsTests {
    let state = WorktreeState(
        id: "id", name: "feat", project: "App", projectRoot: "/p/App", path: "/p/App.worktrees/feat", branch: "feat",
        xcode: XcodeInstall(path: "/Applications/Xcode.app", version: "27.0", build: "27A266a"),
        devices: ["iphone": ProvisionedDevice(udid: "U1", deviceType: "iPhone 18 Pro", deviceTypeIdentifier: "t",
                                              runtime: "iOS 27.0", runtimeIdentifier: "r")],
        status: .ready, createdAt: Date(timeIntervalSince1970: 0))

    @Test func createText() {
        #expect(WorktreeCreateReport(worktree: state, created: true).text == """
        worktree created  name=feat branch=feat
        path: /p/App.worktrees/feat
        next: cd /p/App.worktrees/feat
        """)
        #expect(WorktreeCreateReport(worktree: state, created: false).text.hasPrefix("worktree exists  name=feat"))
    }

    @Test func listText() {
        let entries = [RegistryEntry(state)]
        #expect(WorktreeListReport(worktrees: entries, includeProject: false).text == "feat  ready  /p/App.worktrees/feat")
        #expect(WorktreeListReport(worktrees: entries, includeProject: true).text == "App/feat  ready  /p/App.worktrees/feat")
        #expect(WorktreeListReport(worktrees: [], includeProject: false).text == "no worktrees")
    }

    @Test func statusText() {
        #expect(WorktreeStatusReport(worktree: state).text == """
        worktree feat  branch=feat status=ready
        path: /p/App.worktrees/feat
        xcode: 27.0 (27A266a) /Applications/Xcode.app
        device iphone: iPhone 18 Pro, iOS 27.0  udid=U1
        """)
        var bare = state
        bare.xcode = nil
        bare.devices = [:]
        #expect(WorktreeStatusReport(worktree: bare).text.hasSuffix("""
        xcode: not pinned yet (resolved on first simulator or build use)
        devices: none cloned yet (cloned on first use)
        """))
    }

    @Test func removeText() {
        let r = WorktreeRemoval(name: "feat", path: "/p/x", branch: "feat", removedDevices: ["iphone", "watch"], stateMissing: false)
        #expect(r.text == "removed worktree feat  devices=iphone,watch\nbranch kept: feat")
        let missing = WorktreeRemoval(name: "feat", path: "/p/x", branch: "feat", removedDevices: [], stateMissing: true)
        #expect(missing.text == """
        removed worktree feat  devices=none
        branch kept: feat
        note: the worktree's state was already gone, so any simulators it cloned may remain (named "xcd · <project> · feat · …")
        """)
    }

    @Test func simText() {
        #expect(SimReport(action: "booted", device: "iphone", udid: "U1", retries: 0, worktree: "feat").text == "booted iphone  udid=U1")
        #expect(SimReport(action: "booted", device: "iphone", udid: "U1", retries: 2, worktree: "feat").text == "booted iphone  udid=U1  retries=2")
        #expect(SimReport(action: "not cloned", device: "ipad", udid: nil, retries: 0, worktree: "feat").text
                == "ipad has no clone in this worktree; nothing to do")
    }

    @Test func jsonEnvelopeCarriesWorktree() {
        let json = Renderer.success(SimReport(action: "booted", device: "iphone", udid: "U1", retries: 0, worktree: "feat"),
                                    command: "sim boot", format: .json)
        #expect(json == #"{"command":"sim boot","data":{"action":"booted","device":"iphone","retries":0,"udid":"U1","worktree":"feat"},"ok":true,"worktree":"feat"}"#)
    }

    @Test func configShowIsYAMLWithPins() throws {
        let config = try ConfigLoader.parse(main: "version: 1\nproject: App.xcodeproj\n")
        let text = ConfigReport(config: config, worktree: state).text
        #expect(text.contains("project: App.xcodeproj"))
        #expect(text.hasSuffix("""
        # pinned in worktree 'feat':
        #   xcode: 27.0 (27A266a) /Applications/Xcode.app
        #   iphone: iPhone 18 Pro, iOS 27.0 (U1)
        """))
    }
}
