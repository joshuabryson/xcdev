import AppKit
import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"

/// Each worktree's Mac copy keeps its own data: the fixture app, built with `swiftc` and
/// recorded as the Mac build of two git worktrees, launched hidden under `isolation: suffix` from both at once, and under
/// `shared` beside the other worktree's copy and a stand-in for the user's own. Needs an unlocked screen and the
/// Accessibility grant for the app that runs `swift test`. Run it hands-off: before and after every step the frontmost app
/// and the pointer are read, and no window of the fixture may be on screen. It stops only copies of the fixture, chosen by
/// their full executable path, and removes only the containers `~/Library/Containers/dev.xcdev.MacProbeApp.xcd-*`. Never
/// run with the other integration suites at once.
@Suite(.enabled(if: enabled, "set XCD_INTEGRATION=1 to run (needs the Accessibility grant)"), .serialized)
struct MacIsolationIntegrationTests: HandsOffSuite {
    let runner = SystemProcessRunner()
    let ui = UIOptions(device: "mac", bundle: nil, system: false, role: nil, index: nil, timeout: .seconds(5))
    static let bundleId = macProbeBundleId
    /// The desk checks (`step`, `untouched`, in IntegrationSupport.swift) watch every copy of the fixture, suffixed or not.
    var watchedBundleIds: [String] { Self.ids }
    /// One window at launch, whatever an earlier run left (see `MacUIIntegrationTests.launch`).
    let launchOptions = LaunchOptions(arguments: ["-ApplePersistenceIgnoreState", "YES"])

    /// One worktree of the project, with the fixture recorded as its Mac build.
    struct Checkout {
        let name: String
        let svc: Services
        var ctx: WorktreeContext
        let built: AppProduct
    }

    // MARK: The tests

    @Test(.timeLimit(.minutes(10))) func twoWorktreesUnderSuffixRunApartWithTheirOwnContainers() async throws {
        guard ready() else { return }
        try await withProject(isolation: "suffix", sandboxed: true) { project, fixture in
            let start = try await desk(runner)
            var alpha = try await checkout("alpha", of: project, fixture: fixture)
            var beta = try await checkout("beta", of: project, fixture: fixture)
            let clock = ContinuousClock()
            let began = clock.now
            let first = try await launched(&alpha)
            let made = clock.now - began
            let second = try await launched(&beta)
            for (checkout, report) in [(alpha, first), (beta, second)] {
                ranItsOwnCopy(checkout, report)
                let copyPath = checkout.ctx.paths.macCopies + "/MacProbeApp.app"
                let verified = try await runner.run(Invocation("/usr/bin/codesign", ["--verify", "--strict", copyPath]))
                #expect(verified.succeeded, "codesign --verify \(copyPath): \(verified.stderrString)")
            }
            #expect(alive(first.pid) && alive(second.pid) && first.pid != second.pid, "both copies should run at once")
            try await drivesEachApart(&alpha, &beta)
            try await ownContainer(&alpha, first)
            try await ownContainer(&beta, second)
            try await remakesTheCopyOnlyAfterARebuild(&alpha, firstLaunch: made)
            try await terminatesEachAlone(&alpha, &beta)
            try await untouched(start, "the whole run")
        }
    }

    @Test(.timeLimit(.minutes(10))) func aSharedLaunchBesideAnotherWorktreesCopyIsAppInUseAndTheUsersCopyNeverBlocks() async throws {
        guard ready() else { return }
        try await withProject(isolation: "shared", sandboxed: false) { project, fixture in
            let start = try await desk(runner)
            var alpha = try await checkout("alpha", of: project, fixture: fixture)
            var beta = try await checkout("beta", of: project, fixture: fixture)
            let first = try await launched(&alpha)
            #expect(first.note == RunReport.sharedData(of: Self.bundleId) && first.bundleId == Self.bundleId, "\(first.text)")
            #expect(!FileManager.default.fileExists(atPath: alpha.ctx.paths.macCopies), "a shared launch made a copy")

            let inUse = try await refusedLaunch(&beta, .appInUse)
            // The blocker's worktree comes from its executable's path, which macOS gives with links resolved.
            #expect(inUse?.message == "\(Self.bundleId) is already running from the worktree at \(resolved(alpha.ctx.paths.root)) "
                + "(pid \(first.pid ?? 0)); under isolation: shared both copies would share its data", "\(String(describing: inUse))")
            #expect(inUse?.next == "ask the user, or run `xcd terminate --device mac` in that worktree; "
                + "`isolation: suffix` in .xcdev.yml gives each worktree its own copy")
            #expect(ErrorCode.appInUse.exitCode == 3 && alive(first.pid), "beta's refused launch stopped alpha's copy")

            let user = try await usersOwnCopy(fixture, in: project)
            let second = try await launched(&alpha)        // alpha's own copy is replaced; the user's is not in the way
            #expect(try await ended(first.pid), "alpha's earlier copy still runs after its relaunch")
            #expect(alive(user) && second.pid != first.pid, "alpha's relaunch stopped the user's copy")
            try await terminate(&alpha)
            let third = try await launched(&beta)          // only the user's copy runs now, and it never blocks
            #expect(alive(user) && third.status == .running)
            try await terminate(&beta)
            #expect(alive(user), "a worktree's terminate stopped the user's copy")
            try await untouched(start, "the whole run")
        }
    }

    @Test(.timeLimit(.minutes(5))) func aRefusedProductMakesNoCopy() async throws {
        guard ready() else { return }
        try await withProject(isolation: "suffix", sandboxed: true) { project, fixture in
            let start = try await desk(runner)
            var alpha = try await checkout("alpha", of: project, fixture: fixture)
            // An extension's folder after the signature: the refusal reads the bundle's facts, not its validity.
            try FileManager.default.createDirectory(atPath: alpha.built.path + "/Contents/PlugIns/Share.appex/Contents",
                                                    withIntermediateDirectories: true)
            let refused = try await refusedLaunch(&alpha, .configInvalid)
            #expect(refused?.message.contains("Contents/PlugIns/Share.appex") == true, "\(String(describing: refused))")
            #expect(refused?.next?.contains("devices.mac.isolation: shared") == true, "\(String(describing: refused?.next))")
            #expect(!FileManager.default.fileExists(atPath: alpha.ctx.paths.macCopies), "a refused product left .xcdev/mac")
            #expect(fixturePids().isEmpty, "a refused launch started the app")
            try await untouched(start, "the whole run")
        }
    }

    // MARK: The steps

    /// `xcd launch --device mac` in the checkout, as a step on the desk; the app must still run after the crash watch.
    func launched(_ checkout: inout Checkout) async throws -> RunReport {
        let svc = checkout.svc, name = checkout.name, options = launchOptions
        let report = try await step("xcd launch in \(name)") {
            try await svc.apps.launch(device: "mac", options: options, in: &checkout.ctx)
        }
        try #require(report.status == .running, "\(report.text)")
        return report
    }

    /// A launch that must be refused with `code`, as a step on the desk; returns the error.
    @discardableResult
    func refusedLaunch(_ checkout: inout Checkout, _ code: ErrorCode) async throws -> XcdError? {
        let svc = checkout.svc, name = checkout.name, options = launchOptions
        return try await step("xcd launch in \(name), refused") {
            let error = await #expect(throws: XcdError.self) { _ = try await svc.apps.launch(device: "mac", options: options, in: &checkout.ctx) }
            #expect(error?.code == code, "\(String(describing: error))")
            return error
        }
    }

    func terminate(_ checkout: inout Checkout) async throws {
        let svc = checkout.svc, name = checkout.name
        let report = try await step("xcd terminate in \(name)") { try await svc.apps.terminate(device: "mac", in: &checkout.ctx) }
        #expect(report.action == "terminated", "\(report.text)")
    }

    func label(_ text: String, _ checkout: inout Checkout) async throws {
        let svc = checkout.svc, name = checkout.name, ui = ui
        _ = try await step("xcd ui wait 'label:\(text)' in \(name)") {
            try await svc.ui.wait("label:\(text)", gone: false, ui, in: &checkout.ctx)
        }
    }

    /// Each worktree's `ui` commands reach its own copy: a tap in alpha changes alpha's count and not beta's.
    func drivesEachApart(_ alpha: inout Checkout, _ beta: inout Checkout) async throws {
        try await label("count: 0", &alpha)
        try await label("count: 0", &beta)
        let svc = alpha.svc, ui = ui
        _ = try await step("xcd ui tap id:increment in alpha") { try await svc.ui.tap("id:increment", ui, in: &alpha.ctx) }
        try await label("count: 1", &alpha)
        try await label("count: 0", &beta)
        let other = beta.svc
        let tree = try await step("xcd ui tree in beta") { try await other.ui.tree(all: false, ui, in: &beta.ctx) }
        #expect(tree.tree.hidden == true && tree.tree.elements.contains { $0.identifier == "increment" }, "\(tree.text.prefix(400))")
    }

    /// `xcd sim container --device mac` prints the copy's container, and it is the home the copy logged at launch.
    func ownContainer(_ checkout: inout Checkout, _ launch: RunReport) async throws {
        let svc = checkout.svc, name = checkout.name
        let report = try await step("xcd sim container in \(name)") {
            try await svc.deviceState.container(nil, bundle: nil, device: "mac", in: &checkout.ctx)
        }
        let expected = container(of: checkout)
        #expect(report.path == expected && report.udid == nil, "\(report.text)")
        let home = try await home(loggedIn: launch.appLog)
        #expect(home == expected, "the copy in \(name) logged home=\(String(describing: home))")
    }

    /// On the real copy: a relaunch with nothing rebuilt keeps it; once the build is newer, the next launch
    /// makes it again, with the worktree's identity, alone in `.xcdev/mac`, and running in the worktree's container.
    func remakesTheCopyOnlyAfterARebuild(_ checkout: inout Checkout, firstLaunch: Duration) async throws {
        let before = try #require(suffixedCopy(of: checkout).written)
        let clock = ContinuousClock()
        var began = clock.now
        let fresh = try await launched(&checkout)
        let kept = clock.now - began
        #expect(suffixedCopy(of: checkout).written == before, "a relaunch with nothing rebuilt made the copy again")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: checkout.built.executablePath)
        began = clock.now
        let rebuilt = try await launched(&checkout)
        let remade = clock.now - began
        #expect((suffixedCopy(of: checkout).written ?? .distantPast) > before, "the copy was not made again after the build changed")
        #expect(rebuilt.pid != fresh.pid)
        ranItsOwnCopy(checkout, rebuilt)
        let home = try await home(loggedIn: rebuilt.appLog)
        #expect(home == container(of: checkout), "the remade copy in \(checkout.name) logged home=\(String(describing: home))")
        print("MacIsolation measured: a suffix launch that makes the copy took \(DurationText.format(firstLaunch)), one with the copy "
            + "fresh \(DurationText.format(kept)), one after a rebuild \(DurationText.format(remade)) (each with the 5 s crash watch)")
    }

    /// `xcd terminate` in one worktree stops its own copy and leaves the other running.
    func terminatesEachAlone(_ alpha: inout Checkout, _ beta: inout Checkout) async throws {
        let (first, second) = (lastPid(alpha), lastPid(beta))
        try await terminate(&alpha)
        #expect(try await ended(first), "alpha's copy still runs after its terminate")
        #expect(alive(second), "alpha's terminate stopped beta's copy")
        try await terminate(&beta)
        #expect(try await ended(second), "beta's copy still runs after its terminate")
    }

    /// A stand-in for the user's own copy: the fixture copied outside any `.xcdev` folder and launched hidden by path.
    func usersOwnCopy(_ fixture: String, in project: TempProject) async throws -> Int32? {
        let folder = project.base + "/user-copy"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try await runner.runChecked(Invocation("/usr/bin/ditto", [fixture, folder + "/MacProbeApp.app"]))
        let product = AppProduct(path: folder + "/MacProbeApp.app", bundleId: Self.bundleId, executableName: "MacProbeApp", platform: "macosx")
        let pid = try await step("open -n -g -j the user's copy") {
            try await MacAppHost(runner: runner).launch(product, arguments: ["-ApplePersistenceIgnoreState", "YES"], environment: [:],
                                                         logFile: project.base + "/user-copy.log")
        }
        #expect(alive(pid), "the user's copy did not start")
        return pid
    }

    // MARK: Setting up and cleaning up

    /// A project whose Mac device has `isolation: <mode>`, committed, so every worktree has it.
    func project(isolation: String) throws -> TempProject {
        try TempProject.make(config: """
        version: 1
        project: SampleApp.xcodeproj
        schemes: { app: SampleApp, test: SampleApp }
        defaultDevice: mac
        devices:
          mac: { platform: macOS, isolation: \(isolation) }
        """, name: "Mac Isolation \(UUID().uuidString.prefix(6))", fixture: repoRoot + "/Fixtures/SampleApp", parent: testsHome)
    }

    /// Worktree `name` of the project, made with git and opened by xcd from its folder as an agent's checkout is, with the
    /// fixture recorded as its Mac build.
    func checkout(_ name: String, of project: TempProject, fixture: String) async throws -> Checkout {
        let path = project.base + "/wt/" + name
        try TempProject.git(["worktree", "add", "-q", "-b", name, path], in: project.root)
        let svc = Services(runner: runner, globalPaths: GlobalPaths(base: project.home), currentDirectory: path, environment: [:])
        let ctx = try await svc.open(worktree: nil)
        try #require(ctx.state.name == name, "xcd named the checkout at \(path) \(ctx.state.name)")
        return Checkout(name: name, svc: svc, ctx: ctx, built: try await installMacProbe(in: ctx, from: fixture, runner))
    }

    /// Runs `body` on a new project with the fixture built once into the project's folder, with the App Sandbox
    /// entitlement (so a copy gets a container) or without (so a shared launch makes none for the real bundle id); then
    /// always stops every copy of the fixture under the project's folder (the worktrees' builds and copies, and the
    /// user's stand-in), removes the containers the copies made, and deletes the project.
    func withProject(isolation: String, sandboxed: Bool, _ body: (TempProject, String) async throws -> Void) async throws {
        let project = try project(isolation: isolation)
        defer { project.remove() }
        let fixture = try await buildMacProbe(into: project.base + "/fixture", sandboxed: sandboxed, runner)
        var failure: (any Error)?
        do { try await body(project, fixture) } catch { failure = error }
        await stopCopies(under: project.base)
        let left = try await step("remove the copies' containers") { removeContainers() }
        if !left.isEmpty { print("MacIsolation measured: containers left after the cleanup: \(left)") }
        if let failure { throw failure }
    }

    /// Stops every copy of the fixture whose executable lies under `folder`, chosen by its full path, never by name.
    func stopCopies(under folder: String) async {
        let copies = fixtureApps().filter { $0.executableURL?.path.hasPrefix(resolved(folder) + "/") == true }
        for copy in copies { _ = try? await runner.run(Invocation("/bin/kill", ["-TERM", String(copy.processIdentifier)])) }
        for copy in copies { _ = try? await ended(copy.processIdentifier) }
    }

    /// Removes the containers suffixed copies of the fixture made, and only those. Returns the ones still there (macOS may
    /// refuse to delete a container), for the run's record.
    func removeContainers() -> [String] {
        let root = NSHomeDirectory() + "/Library/Containers"
        let made = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { $0.hasPrefix(Self.bundleId + ".xcd-") }
        for name in made { try? FileManager.default.removeItem(atPath: root + "/" + name) }
        return made.filter { FileManager.default.fileExists(atPath: root + "/" + $0) }
    }

    /// What the run needs, checked before anything starts: each missing one is one issue that says what to do.
    func ready() -> Bool {
        let host = MacHostApp.live()
        let lock = MacScreenLock.refusal
        let running = fixturePids()
        let missing = [
            MacScreenLock.isLocked() ? "\(lock.message); \(lock.next ?? "")" : nil,
            SystemAccessibility().isTrusted ? nil : "\(host) has no Accessibility permission; \(MacPermissions.accessibilityNext(host))",
            running.isEmpty ? nil : "a copy of the fixture already runs (pids \(running.sorted())); quit it first, since a shared launch would count it",
        ].compactMap { $0 }
        for problem in missing { Issue.record(Comment(rawValue: problem)) }
        return missing.isEmpty
    }

    // MARK: Reading what came out

    /// The worktree's suffixed bundle id, and the container a sandboxed copy under it gets.
    func suffixedId(of checkout: Checkout) -> String { Self.bundleId + ".xcd-" + checkout.name }
    func container(of checkout: Checkout) -> String { NSHomeDirectory() + "/Library/Containers/\(suffixedId(of: checkout))/Data" }

    /// The launch ran the worktree's own copy: the report names the suffixed id and notes it, the copy's Info.plist has
    /// it, and `.xcdev/mac` holds the copy alone (no `.partial`, no entitlements file).
    func ranItsOwnCopy(_ checkout: Checkout, _ report: RunReport) {
        let id = suffixedId(of: checkout)
        #expect(report.bundleId == id && report.note == "isolation: \(id)", "\(report.text)")
        #expect(suffixedCopy(of: checkout).bundleId == id, "the copy in \(checkout.name): \(suffixedCopy(of: checkout))")
        let copies = try? FileManager.default.contentsOfDirectory(atPath: checkout.ctx.paths.macCopies)
        #expect(copies == ["MacProbeApp.app"], "\(checkout.ctx.paths.macCopies) holds \(String(describing: copies))")
    }

    /// The worktree's suffixed copy: its bundle id, and when its executable was last written (the copy's re-sign writes it).
    func suffixedCopy(of checkout: Checkout) -> (bundleId: String?, written: Date?) {
        let app = checkout.ctx.paths.macCopies + "/MacProbeApp.app"
        let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")
        let attributes = try? FileManager.default.attributesOfItem(atPath: app + "/Contents/MacOS/MacProbeApp")
        return (info?["CFBundleIdentifier"] as? String, attributes?[.modificationDate] as? Date)
    }

    /// The `home=` the app logged at launch (`launched pid=… home=… hidden=…`): its container when sandboxed. Each launch
    /// writes its own log, and the last such line is read, so a log that held two launches would give the later one. The
    /// line is there once the crash watch has passed; this looks for up to 5 s more.
    func home(loggedIn appLog: String?) async throws -> String? {
        let log = try #require(appLog, "the launch named no app log")
        for _ in 0..<20 {
            let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
            if let line = text.split(separator: "\n").last(where: { $0.hasPrefix("launched pid=") }),
               let start = line.range(of: " home="), let end = line.range(of: " hidden=") {
                return String(line[start.upperBound..<end.lowerBound])
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    func lastPid(_ checkout: Checkout) -> Int32? { (try? AppStateStore.load(checkout.ctx.paths))?.lastLaunch?.pid }
    func alive(_ pid: Int32?) -> Bool { pid.map { kill($0, 0) == 0 } ?? false }

    /// Waits up to 5 s for the process to end; true when it did.
    func ended(_ pid: Int32?) async throws -> Bool {
        for _ in 0..<20 where alive(pid) { try await Task.sleep(for: .milliseconds(250)) }
        return !alive(pid)
    }

    /// `path` with every link resolved, `/private` kept, as macOS gives a running app's executable.
    func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    /// The bundle ids a copy of the fixture runs under in this suite: its own, and the two worktrees' suffixed ones.
    static let ids = [bundleId, bundleId + ".xcd-alpha", bundleId + ".xcd-beta"]

    /// Every running copy of the fixture under those ids. `runningApplications(withBundleIdentifier:)` asks afresh each
    /// time, as `MacUIIntegrationTests` and `SystemRunningApps` do; `NSWorkspace`'s list changes only while a main run
    /// loop runs, which a test process does not promise.
    func fixtureApps() -> [NSRunningApplication] {
        Self.ids.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    }
    func fixturePids() -> Set<Int32> { Set(fixtureApps().map(\.processIdentifier)) }
}
