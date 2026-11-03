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
        var branched = state
        branched.base = "main"
        let next = "next: cd /p/App.worktrees/feat, then run xcd build, xcd test, or xcd run"
        #expect(WorktreeCreateReport(worktree: branched, created: true, branchCreated: true,
                                     packagesSeeded: true, hookRan: true).text == """
        worktree created  name=feat branch=feat
        path: /p/App.worktrees/feat
        setup: new branch from main; DerivedData at .xcdev/DerivedData, empty until the first build; simulators clone on first use; source packages copied from the main checkout; post-worktree-create ran
        \(next)
        """)
        #expect(WorktreeCreateReport(worktree: state, created: true).text == """
        worktree created  name=feat branch=feat
        path: /p/App.worktrees/feat
        setup: existing branch feat; DerivedData at .xcdev/DerivedData, empty until the first build; simulators clone on first use
        \(next)
        """)
        #expect(WorktreeCreateReport(worktree: state, created: false).text == """
        worktree exists  name=feat branch=feat
        path: /p/App.worktrees/feat
        \(next)
        """)
        let json = Renderer.report(WorktreeCreateReport(worktree: branched, created: true, branchCreated: true),
                                   command: "wt create", format: .json)
        #expect(json.contains(#""branchCreated":true"#))
        #expect(json.contains(#""packagesSeeded":false"#))
        #expect(json.contains(#""hookRan":false"#))
    }

    @Test func listText() {
        let feat = WorktreeListItem(entry: RegistryEntry(state), status: .ready, branch: "feat", devices: [
            .init(name: "iphone", udid: "U1", state: "Booted"),
            .init(name: "watch", udid: "U2", state: "gone"),
        ])
        let bare = WorktreeListItem(entry: RegistryEntry(state), status: .missing, branch: nil, devices: [])
        #expect(WorktreeListReport(worktrees: [feat], includeProject: false).text
                == "feat  ready  branch=feat  devices=iphone:Booted,watch:gone  /p/App.worktrees/feat")
        #expect(WorktreeListReport(worktrees: [feat, bare], includeProject: true).text == """
        App/feat  ready  branch=feat  devices=iphone:Booted,watch:gone  /p/App.worktrees/feat
        App/feat  missing  branch=-  devices=none  /p/App.worktrees/feat
        """)
        #expect(WorktreeListReport(worktrees: [], includeProject: false).text == "no worktrees")
    }

    @Test func listJSONCarriesFields() {
        let item = WorktreeListItem(entry: RegistryEntry(state), status: .ready, branch: "feat",
                                    devices: [.init(name: "iphone", udid: "U1", state: "Shutdown")])
        let json = Renderer.report(WorktreeListReport(worktrees: [item], includeProject: false), command: "wt list", format: .json)
        #expect(json == #"{"command":"wt list","data":{"includeProject":false,"worktrees":[{"branch":"feat","devices":[{"name":"iphone","state":"Shutdown","udid":"U1"}],"name":"feat","path":"/p/App.worktrees/feat","project":"App","status":"ready"}]},"ok":true}"#)
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
        let r = WorktreeRemoval(name: "feat", project: "App", path: "/p/x", branch: "feat", removedDevices: ["iphone", "watch"], stateMissing: false)
        #expect(r.text == """
        removed worktree feat  devices=iphone,watch
        branch kept: feat
        disk freed: not measured
        """)
        let missing = WorktreeRemoval(name: "feat", project: "App", path: "/p/x", branch: "feat", removedDevices: [], stateMissing: true)
        #expect(missing.text == """
        removed worktree feat  devices=none
        branch kept: feat
        disk freed: not measured
        note: the worktree's state was already gone, so any simulators it cloned may remain (named "xcd · App · feat · …")
        """)
        var gone = missing
        gone.checkoutBytes = 0
        gone.stateBytes = 0
        gone.cloneBytes = 0
        #expect(gone.text.contains("disk freed: 0B"))
        var sized = r
        sized.checkoutBytes = 180 * 1024 * 1024
        sized.stateBytes = 900 * 1024 * 1024
        sized.cloneBytes = 120 * 1024 * 1024
        #expect(sized.text.contains("disk freed: 1.2GB (checkout 180.0MB, build state 900.0MB, simulators 120.0MB)"))
        let foreign = WorktreeRemoval(name: "feat", project: "App", path: "/p/x", branch: "feat", removedDevices: ["iphone"],
                                      stateMissing: false, keptCheckout: true, stateBytes: 100 * 1024 * 1024, cloneBytes: 0)
        #expect(foreign.checkoutBytes == nil)
        #expect(foreign.text.contains("disk freed: 100.0MB (build state 100.0MB)"))
        let json = Renderer.report(r, command: "wt remove", format: .json)
        #expect(!json.contains("checkoutBytes"))
    }

    @Test func simText() {
        #expect(SimReport(action: "booted", device: "iphone", udid: "U1", retries: 0, worktree: "feat").text == "booted iphone  udid=U1")
        #expect(SimReport(action: "booted", device: "iphone", udid: "U1", retries: 2, worktree: "feat").text == "booted iphone  udid=U1  retries=2")
        #expect(SimReport(action: "not cloned", device: "ipad", udid: nil, retries: 0, worktree: "feat").text
                == "ipad has no clone in this worktree; nothing to do")
    }

    @Test func jsonEnvelopeCarriesWorktree() {
        let json = Renderer.report(SimReport(action: "booted", device: "iphone", udid: "U1", retries: 0, worktree: "feat"),
                                    command: "sim boot", format: .json)
        #expect(json == #"{"command":"sim boot","data":{"action":"booted","device":"iphone","notes":[],"retries":0,"udid":"U1","worktree":"feat"},"ok":true,"worktree":"feat"}"#)
    }

    @Test func simReportJSONCarriesIdleOnlyWhenSet() {
        var report = SimReport(action: "booted", device: "iphone", udid: "U1", retries: 0, worktree: "feat")
        #expect(!Renderer.report(report, command: "sim boot", format: .json, notes: []).contains("idle"))
        report.idle = 600
        #expect(Renderer.report(report, command: "sim boot", format: .json, notes: []).contains(#""idle":600"#))
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
