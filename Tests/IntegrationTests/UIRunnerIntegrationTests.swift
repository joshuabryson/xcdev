import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"

@Suite(.enabled(if: enabled, "set XCD_INTEGRATION=1 to run (needs Xcode + an iOS simulator runtime)"), .serialized)
struct UIRunnerIntegrationTests {
    let runner = SystemProcessRunner()

    @Test(.timeLimit(.minutes(15))) func theEmbeddedRunnerBuildsWithNoSigningSetup() async throws {
        let dir = testsHome + "/runner-build-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try RunnerSource.write(to: dir + "/project")
        let out = try await runner.run(.xcrun(["xcodebuild", "build-for-testing", "-project", dir + "/project/" + RunnerSource.projectPath,
                                               "-scheme", RunnerSource.scheme, "-destination", "generic/platform=iOS Simulator",
                                               "-derivedDataPath", dir + "/DerivedData"], developerDir: nil, timeout: .seconds(840)))
        #expect(out.succeeded, "\(out.stdoutString.suffix(3000))\n\(out.stderrString.suffix(2000))")
        let products = dir + "/DerivedData/Build/Products"
        let runs = try FileManager.default.contentsOfDirectory(atPath: products).filter { $0.hasSuffix(".xctestrun") }
        #expect(runs.count == 1)
    }

    @Test(.timeLimit(.minutes(30))) func readTapAndWaitWithoutTakingFocusOnTheMac() async throws {
        try await withApp { ctx, svc in
            let simulatorWasRunning = try await simulatorAppIsRunning()
            let front = try await frontmostMacApp()

            try await readsTheSampleScreen(&ctx, svc)
            try await tapsAndWaits(&ctx, svc)
            try await refusesWhatCannotBeTapped(&ctx, svc)

            let nowFront = try await frontmostMacApp()
            #expect(nowFront == front, "driving the simulator changed the frontmost Mac app from \(front) to \(nowFront)")
            #expect(!nowFront.contains("Simulator"), "Simulator.app is in front: \(nowFront)")
            #expect(try await simulatorAppIsRunning() == simulatorWasRunning, "a ui command started Simulator.app")
        }
    }

    @Test(.timeLimit(.minutes(30))) func aPermissionAlertIsInTheTreeAndCanBeTapped() async throws {
        try await withApp { ctx, svc in
            _ = try await svc.ui.tap("id:askPhotos", options, in: &ctx)
            try await waitForThePhotosAlert(&ctx, svc)
            let tree = try await svc.ui.tree(all: false, options, in: &ctx).tree
            #expect(tree.elements.contains { $0.source == .app && $0.identifier == "signInButton" }, "the app is still listed under the alert")
            let system = tree.elements.filter { $0.source == .system }
            #expect(system.contains { $0.role == "alert" }, "no system alert in: \(system.map(\.label))")

            // The alert covers the app's buttons, so a tap on one is refused rather than landing on the alert.
            let covered = await #expect(throws: XcdError.self) { _ = try await svc.ui.tap("id:signInButton", options, in: &ctx) }
            #expect(covered?.code == .elementNotHittable && covered?.message.contains("covered by a system alert") == true, "\(String(describing: covered))")

            let deny = try #require(try await svc.ui.tree(all: false, options, in: &ctx).tree.elements.first {
                $0.source == .system && $0.role == "button" && $0.label.contains("Don")
            }, "no deny button in: \(system.map(\.label))")
            let tapped = try await svc.ui.tap("ref:\(try #require(deny.ref))", options, in: &ctx)
            #expect(tapped.element?.source == .system && tapped.element?.label == deny.label)
            var long = options
            long.timeout = .seconds(20)
            _ = try await svc.ui.wait("label~Allow", gone: true, long, in: &ctx)
            // With the alert answered, the same button can be tapped again.
            _ = try await svc.ui.tap("id:signInButton", options, in: &ctx)
            _ = try await svc.ui.wait("id:welcome", gone: false, options, in: &ctx)
        }
    }

    @Test(.timeLimit(.minutes(30))) func badRequestsNeverKillTheRunner() async throws {
        try await withApp { ctx, svc in
            let session = try await svc.runners.session(device: nil, in: &ctx)
            let transport = URLSessionRunnerTransport()
            for (path, body) in [("/nope", "{}"), ("/tap", "not json"), ("/tap", "{}"), ("/tree", "[1,2,3]")] {
                let reply = try await transport.send(to: session.endpoint, path: path, body: Data(body.utf8), timeout: .seconds(20))
                let text = String(decoding: reply.body, as: UTF8.self)
                #expect(reply.status == 200 && text.contains(#""ok":false"#), "\(path) \(body): HTTP \(reply.status) \(text)")
            }
            let rejected = try await transport.send(to: RunnerEndpoint(port: session.port, token: "wrong"), path: "/health", body: nil, timeout: .seconds(20))
            #expect(rejected.status == 401)
            var other = options
            other.bundle = "com.example.notinstalled"
            #expect(try await svc.ui.tree(all: false, other, in: &ctx).tree.state == "not_running")
            // A well-formed request that matches nothing is an ordinary failure, not a runner problem.
            let unmatched = await #expect(throws: XcdError.self) { _ = try await svc.ui.tap("id:nope", options, in: &ctx) }
            #expect(unmatched?.code == .elementNotFound, "\(String(describing: unmatched))")
            #expect(await svc.runners.client.health(session.endpoint)?.rolesVerified == true)
            let again = try await svc.runners.session(device: nil, in: &ctx)
            #expect(again.token == session.token && again.port == session.port && !again.restarted)   // same runner, never restarted
            #expect(try await svc.ui.tree(all: false, options, in: &ctx).tree.state == "foreground")
        }
    }

    @Test(.timeLimit(.minutes(30))) func aKilledRunnerIsReplacedAndStopLeavesNothingBehind() async throws {
        try await withApp { ctx, svc in
            let before = try await svc.ui.tree(all: false, options, in: &ctx)
            #expect(!before.restarted)
            let record = try #require(Runners.load(ctx.paths.runnerFile(device: "iphone")))
            // The simulator's runner wrote its ready file into xcd's cache, not into the worktree.
            #expect(record.readyFile == svc.runners.globalPaths.runnerReadyFile(udid: before.udid))
            #expect(FileManager.default.fileExists(atPath: record.readyFile))
            try #require(record.process.pid > 1)                            // a group id of 0 or 1 would signal far more than the runner
            kill(-record.process.pid, SIGKILL)
            try await Task.sleep(for: .seconds(2))
            let after = try await svc.ui.tree(all: false, options, in: &ctx)
            #expect(after.restarted && after.tree.state == "foreground")
            let replacement = try #require(Runners.load(ctx.paths.runnerFile(device: "iphone")))
            #expect(replacement.process.pid != record.process.pid && replacement.token != record.token)
            let stopped = try await svc.ui.stop(device: nil, rebuild: false, in: &ctx)
            #expect(stopped.stopped == ["stopped the iphone UI runner"])
            #expect(ctx.paths.runnerFiles.isEmpty && !FileManager.default.fileExists(atPath: replacement.readyFile))
            let left = try await runner.run(Invocation("/usr/bin/pgrep", ["-f", "test-without-building.*\(after.udid)"]))
            #expect(!left.succeeded, "an xcodebuild for this clone is still running: \(left.stdoutString)")
        }
    }
}

/// What the driving tests share: a throwaway SampleApp project, the app running on its own clone, and the Mac's state.
extension UIRunnerIntegrationTests {
    var options: UIOptions { UIOptions(device: nil, bundle: nil, system: false, role: nil, index: nil, timeout: .seconds(5)) }

    func project() async throws -> TempProject {
        let phone = try await firstIPhoneType(runner)
        return try TempProject.make(config: """
        version: 1
        project: SampleApp.xcodeproj
        schemes: { app: SampleApp, test: SampleApp }
        defaultDevice: iphone
        devices:
          iphone: { type: "\(phone.name)" }
        """, name: "UI App \(UUID().uuidString.prefix(6))", fixture: repoRoot + "/Fixtures/SampleApp", parent: testsHome)
    }

    /// The frontmost Mac app, as `lsappinfo` reports it. At the login window or a locked screen it is `loginwindow`.
    func frontmostMacApp() async throws -> String {
        let front = try await runner.run(Invocation("/usr/bin/lsappinfo", ["front"])).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = try await runner.run(Invocation("/usr/bin/lsappinfo", ["info", "-only", "name", front])).stdoutString
        return info.split(separator: "\n").first.map(String.init) ?? info
    }

    func simulatorAppIsRunning() async throws -> Bool {
        try await runner.run(Invocation("/usr/bin/pgrep", ["-x", "Simulator"])).succeeded
    }

    /// Runs `body` with the app built and launched, and always stops the runner and deletes the clone afterwards.
    func withApp(_ body: (inout WorktreeContext, Services) async throws -> Void) async throws {
        try await withCleanup(try await project()) { svc in
            var ctx = try await svc.open(worktree: nil)
            do {
                let run = try await svc.apps.run(BuildOptions(), noBuild: false, launch: LaunchOptions(environment: [:]), in: &ctx)
                try #require(run.status == .running, "\(run.text)")
                try await body(&ctx, svc)
            } catch {
                _ = await Runners.stopAll(in: ctx.paths, detached: svc.detached)
                throw error
            }
            _ = await Runners.stopAll(in: ctx.paths, detached: svc.detached)
        }
    }

    func element(_ identifier: String, _ ctx: inout WorktreeContext, _ svc: Services) async throws -> TreeElement {
        let elements = try await svc.ui.tree(all: false, options, in: &ctx).tree.elements
        return try #require(elements.first { $0.identifier == identifier }, "\(identifier) is missing from: \(elements.map(\.identifier))")
    }

    func readsTheSampleScreen(_ ctx: inout WorktreeContext, _ svc: Services) async throws {
        let tree = try await svc.ui.tree(all: false, options, in: &ctx).tree
        #expect(tree.state == "foreground" && tree.scale >= 2 && tree.screen.w > 300)
        let ids = tree.elements.map(\.identifier)
        for expected in ["emailField", "rememberMe", "signInButton", "gearButton", "disabledButton", "tapCount", "askPhotos"] {
            #expect(ids.contains(expected), "\(expected) is missing from: \(ids)")
        }
        let email = try #require(tree.elements.first { $0.identifier == "emailField" })
        #expect(email.role == "textField" && email.placeholder == "Email" && (email.value ?? "").isEmpty)   // the placeholder is not its value
        #expect(tree.elements.first { $0.identifier == "rememberMe" }?.value == "0")
        #expect(tree.elements.first { $0.identifier == "disabledButton" }?.enabled == false)
        #expect(tree.elements.filter { $0.label == "Sign In" }.map(\.role) == ["button"])                   // the button, not also its text
        #expect(tree.elements.allSatisfy { $0.source == .app && !$0.offscreen && $0.ref != nil })
        let all = try await svc.ui.tree(all: true, options, in: &ctx).tree
        #expect(all.elements.contains { $0.offscreen && $0.label.hasPrefix("Row ") })
        #expect(all.elements.count > tree.elements.count && all.elements.first?.role == "application")
    }

    func tapsAndWaits(_ ctx: inout WorktreeContext, _ svc: Services) async throws {
        let tapped = try await svc.ui.tap("label:Sign In", options, in: &ctx)
        #expect(tapped.element?.identifier == "signInButton")
        #expect(try await svc.ui.wait("id:welcome", gone: false, options, in: &ctx).element?.label == "Welcome back")

        let gear = try await element("gearButton", &ctx, svc)
        _ = try await svc.ui.tap("ref:\(try #require(gear.ref))", options, in: &ctx)
        #expect(try await svc.ui.wait("label:taps: 1", gone: false, options, in: &ctx).element?.identifier == "tapCount")
        // A point tap lands where the tree says the element is.
        let point = try await svc.ui.tap("@\(gear.frame.midX),\(gear.frame.midY)", options, in: &ctx)
        #expect(point.element == nil && point.x == gear.frame.midX && point.y == gear.frame.midY)
        _ = try await svc.ui.wait("label:taps: 2", gone: false, options, in: &ctx)
        _ = try await svc.ui.wait("label:taps: 1", gone: true, options, in: &ctx)
    }

    func refusesWhatCannotBeTapped(_ ctx: inout WorktreeContext, _ svc: Services) async throws {
        let missing = await #expect(throws: XcdError.self) { _ = try await svc.ui.tap("id:nope", options, in: &ctx) }
        #expect(missing?.code == .elementNotFound)
        let disabled = await #expect(throws: XcdError.self) { _ = try await svc.ui.tap("id:disabledButton", options, in: &ctx) }
        #expect(disabled?.code == .elementNotHittable)
        let stale = await #expect(throws: XcdError.self) { _ = try await svc.ui.tap("ref:e999", options, in: &ctx) }
        #expect(stale?.code == .staleRef)
        let never = await #expect(throws: XcdError.self) { _ = try await svc.ui.wait("id:nope", gone: false, options, in: &ctx) }
        #expect(never?.code == .waitTimeout)
        #expect(try await element("tapCount", &ctx, svc).label == "taps: 2", "a refused tap changed the screen")
    }

    /// Waits for the Photos prompt. On a brand-new clone its first appearance waits for the photo library to be set
    /// up, which can take longer than a default wait; later ones take under a second.
    func waitForThePhotosAlert(_ ctx: inout WorktreeContext, _ svc: Services) async throws {
        var long = options
        long.timeout = .seconds(120)
        for attempt in 1...3 {
            do {
                _ = try await svc.ui.wait("label~Allow", gone: false, long, in: &ctx)
                return
            } catch let error as XcdError where error.code == .waitTimeout && attempt < 3 {
                continue
            }
        }
    }
}
