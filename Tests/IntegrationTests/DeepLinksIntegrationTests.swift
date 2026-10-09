import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"

/// `xcd open` on a real simulator clone that has never opened the sample app's scheme.
@Suite(.enabled(if: enabled, "set XCD_INTEGRATION=1 to run (needs Xcode + an iOS simulator runtime)"), .serialized)
struct DeepLinksIntegrationTests {
    let runner = SystemProcessRunner()
    var ui: UIOptions { UIOptions(device: nil, bundle: nil, system: false, role: nil, index: nil, timeout: .seconds(15)) }

    func project() async throws -> TempProject {
        let phone = try await firstIPhoneType(runner)
        return try TempProject.make(config: """
        version: 1
        project: SampleApp.xcodeproj
        schemes: { app: SampleApp, test: SampleApp }
        defaultDevice: iphone
        devices:
          iphone: { type: "\(phone.name)" }
        presets:
          greeting: { env: { GREETING: preset } }
        deeplinks:
          vars:
            base: "sampleapp://sample"
          routes:
            item:
              description: "Show one item"
              url: "{base}/item?id={id}&tab={tab}"
              expect: "label~item?id={id}"
              params:
                id:  { description: "The item's id" }
                tab: { description: "Which tab to show", values: [notes, preview], optional: true }
            shown:
              description: "Show one item, with a check that any link satisfies"
              url: "{base}/item?id={id}&tab={tab}"
              expect: "id:arrivalValue"
              params:
                id:  { description: "The item's id" }
                tab: { description: "Which tab to show", values: [notes, preview], optional: true }
            greeted:
              description: "The home screen after a restart with the greeting preset"
              url: "{base}/home"
              preset: greeting
            start:
              description: "Start at a route given as a launch argument"
              launch: { args: ["-startRoute", "onboarding/{step}"] }
              expect: "label:onboarding/{step}"
              params:
                step: { description: "1 to 4", default: 1 }
            crash:
              description: "A link the sample app crashes on"
              url: "sampleapp://crash"
            seeded:
              description: "Seed a sample item and show it"
              run: ./scripts/seed-item.sh
              expect: "label:seeded/{id}"
              params:
                id: { description: "The item to seed", default: 1 }
            web:
              description: "A web link that no app on the simulator takes, so Safari opens it"
              url: "https://example.com/xcd-sample"
              expect: "label~xcd-sample"
        """, name: "Links App \(UUID().uuidString.prefix(6))", fixture: repoRoot + "/Fixtures/SampleApp", parent: testsHome)
    }

    /// Builds and installs the sample app without starting it, runs `body`, and always stops the runner and deletes the clone.
    func withInstalledApp(_ body: (inout WorktreeContext, Services) async throws -> Void) async throws {
        try await withCleanup(try await project()) { svc in
            var ctx = try await svc.open(worktree: nil)
            do {
                let build = try await svc.builds.build(BuildOptions(), in: &ctx)
                try #require(build.succeeded, "\(build.text)")
                _ = try await svc.apps.install(device: nil, in: &ctx)
                try await body(&ctx, svc)
            } catch {
                _ = await Runners.stopAll(in: ctx.paths, detached: svc.detached)
                throw error
            }
            _ = await Runners.stopAll(in: ctx.paths, detached: svc.detached)
        }
    }

    /// Waits for the sample app to show `value` as what it was asked for, and returns how it says the request arrived.
    /// No system alert may be on screen: an "Open in …?" alert is what an unapproved scheme would leave there.
    func arrival(of value: String, _ ctx: inout WorktreeContext, _ svc: Services) async throws -> String {
        _ = try await svc.ui.wait("label:" + value, gone: false, ui, in: &ctx)
        let tree = try await svc.ui.tree(all: false, ui, in: &ctx).tree
        let alerts = tree.elements.filter { $0.source == .system }
        #expect(alerts.isEmpty, "a system alert is up: \(alerts.map(\.label))")
        #expect(tree.elements.first { $0.identifier == "arrivalValue" }?.label == value)
        return try #require(tree.elements.first { $0.identifier == "arrivalSource" }?.label, "the sample app shows no arrival")
    }

    @Test(.timeLimit(.minutes(30))) func everyKindOfRouteReachesTheApp() async throws {
        try await withInstalledApp { ctx, svc in
            let list = svc.routes.list(in: ctx)
            #expect(list.routes.map(\.name) == ["crash", "greeted", "item", "seeded", "shown", "start", "web"])
            #expect(list.routes.map(\.kind) == ["url", "url", "url", "run", "url", "launch", "url"])
            let planned = try await svc.routes.open(.route(name: "item", values: ["id": "dry"]), OpenOptions(dryRun: true), in: &ctx)
            #expect(planned.url == "sampleapp://sample/item?id=dry" && ctx.state.devices["iphone"] != nil)

            // Not running: xcd starts the app, then sends the link. The clone has never seen this scheme. The route's
            // `expect` is looked for while the app is watched, and this first look builds and starts the UI runner.
            let started = try await svc.routes.open(.route(name: "item", values: ["id": "42"]), OpenOptions(), in: &ctx)
            #expect(started.app?.state == .started && started.failure == nil, "\(started.text)")
            #expect(started.check?.outcome == .appeared && started.check?.target == "label~item?id=42", "\(started.text)")
            #expect(try await arrival(of: "sampleapp://sample/item?id=42", &ctx, svc) == "warm")

            // Running: the link goes to the same process. What it expects was not on screen before, and is after.
            let warm = try await svc.routes.open(.route(name: "item", values: ["id": "43"]), OpenOptions(), in: &ctx)
            #expect(warm.app?.state == .running && warm.app?.pid == started.app?.pid, "\(warm.text)")
            #expect(warm.check?.outcome == .appeared && warm.failure == nil, "\(warm.text)")
            #expect(try await arrival(of: "sampleapp://sample/item?id=43", &ctx, svc) == "warm")

            // An `expect` that any link satisfies was on screen already, so it proves nothing, and the result says so.
            // The link is still sent, encoded.
            let vague = try await svc.routes.open(.route(name: "shown", values: ["id": "a b", "tab": "notes"]), OpenOptions(), in: &ctx)
            #expect(vague.check?.outcome == .inconclusive && vague.failure == nil, "\(vague.text)")
            #expect(try await arrival(of: "sampleapp://sample/item?id=a%20b&tab=notes", &ctx, svc) == "warm")

            // A launch route restarts the app with its arguments.
            let launched = try await svc.routes.open(.route(name: "start", values: ["step": "3"]), OpenOptions(), in: &ctx)
            #expect(launched.app?.state == .restarted && launched.app?.pid != started.app?.pid, "\(launched.text)")
            #expect(launched.check?.outcome == .appeared, "\(launched.text)")
            #expect(try await arrival(of: "onboarding/3", &ctx, svc) == "argument")

            // A route with a preset restarts the app with it, then sends the link.
            let greeted = try await svc.routes.open(.route(name: "greeted", values: [:]), OpenOptions(), in: &ctx)
            #expect(greeted.app?.state == .restarted && greeted.preset == "greeting", "\(greeted.text)")
            #expect(try await arrival(of: "sampleapp://sample/home", &ctx, svc) == "warm")
            let output = try String(contentsOfFile: try #require(greeted.app?.log), encoding: .utf8)
            #expect(output.contains("SampleApp launched greeting=preset"))

            try await coldStart(&ctx, svc)
            try await aLaunchRouteStartsAStoppedApp(&ctx, svc)
            try await otherSpellingsOfTheScheme(&ctx, svc)
            try await aScriptRoute(&ctx, svc)
            try await aWebLinkThatSafariTakes(&ctx, svc)
        }
    }

    /// The project's own script gets the route's values and the worktree's context, and its `expect` is checked once
    /// it has exited. xcd leaves the app to the script.
    func aScriptRoute(_ ctx: inout WorktreeContext, _ svc: Services) async throws {
        let seeded = try await svc.routes.open(.route(name: "seeded", values: ["id": "7"]), OpenOptions(), in: &ctx)
        #expect(seeded.app?.state == .untouched && seeded.app?.bundleId == "dev.xcdev.SampleApp" && seeded.failure == nil, "\(seeded.text)")
        #expect(seeded.check?.outcome == .appeared && seeded.check?.target == "label:seeded/7", "\(seeded.text)")
        let output = try String(contentsOfFile: try #require(seeded.scriptLog), encoding: .utf8)
        #expect(output.contains("seeding item 7 for route seeded on iphone"), "\(output)")
        #expect(try await arrival(of: "seeded/7", &ctx, svc) == "argument")
        // The default value reaches the script too.
        let byDefault = try await svc.routes.open(.route(name: "seeded", values: [:]), OpenOptions(), in: &ctx)
        #expect(byDefault.check?.target == "label:seeded/1" && byDefault.check?.outcome == .appeared, "\(byDefault.text)")
    }

    /// No app on the simulator takes this https link, so the system gives it to Safari and `simctl` still reports
    /// success. The route's `expect` is what catches it. Safari is left in front: this runs last.
    func aWebLinkThatSafariTakes(_ ctx: inout WorktreeContext, _ svc: Services) async throws {
        let web = try await svc.routes.open(.route(name: "web", values: [:]), OpenOptions(), in: &ctx)
        #expect(web.linkSent == true && web.check?.outcome == .missing, "\(web.text)")
        #expect(web.failure?.code == .waitTimeout, "\(String(describing: web.failure))")
        #expect(web.failure?.message == "the link was sent, but label~xcd-sample did not appear within 10.0s")
        #expect(web.failure?.next?.contains("an https link opens in Safari") == true, "\(String(describing: web.failure?.next))")
    }

    /// `--cold`: the system starts the app because of the link, and xcd can still stop it afterwards.
    func coldStart(_ ctx: inout WorktreeContext, _ svc: Services) async throws {
        let cold = try await svc.routes.open(.route(name: "item", values: ["id": "cold"]), OpenOptions(cold: true), in: &ctx)
        #expect(cold.app?.state == .startedByLink && cold.app?.log == nil && cold.failure == nil, "\(cold.text)")
        #expect(cold.check?.outcome == .appeared, "\(cold.text)")
        #expect(try await arrival(of: "sampleapp://sample/item?id=cold", &ctx, svc) == "cold")
        let record = try #require(try AppStateStore.load(ctx.paths).lastLaunch)
        #expect(record.pid == cold.app?.pid)
        let logs = try await svc.logs.logs(LogOptions(appOutput: true), in: &ctx)
        #expect(logs.lines.count == 1 && logs.lines.first?.contains("was not captured") == true, "\(logs.text)")
        #expect(try await svc.apps.terminate(device: nil, in: &ctx).action == "terminated")
    }

    /// A launch route on an app that is not running starts it. The cold start above left the app stopped.
    func aLaunchRouteStartsAStoppedApp(_ ctx: inout WorktreeContext, _ svc: Services) async throws {
        let launched = try await svc.routes.open(.route(name: "start", values: ["step": "4"]), OpenOptions(), in: &ctx)
        #expect(launched.app?.state == .started && launched.failure == nil, "\(launched.text)")
        #expect(try await arrival(of: "onboarding/4", &ctx, svc) == "argument")
        // The next step sends a link to a stopped app again.
        #expect(try await svc.apps.terminate(device: nil, in: &ctx).action == "terminated")
    }

    /// The simulator approves a scheme letter for letter, so a link in capitals and the app's second scheme each need
    /// their own approval. Neither may leave an alert.
    func otherSpellingsOfTheScheme(_ ctx: inout WorktreeContext, _ svc: Services) async throws {
        let capitals = try await svc.routes.open(.url("SAMPLEAPP://sample/capitals"), OpenOptions(), in: &ctx)
        #expect(capitals.route == nil && capitals.app?.state == .started, "\(capitals.text)")
        #expect(try await arrival(of: "SAMPLEAPP://sample/capitals", &ctx, svc) == "warm")
        // `sim open-url` approves a scheme the built app registers. The app writes this one as "SampleCaps".
        _ = try await svc.deviceState.openURL("samplecaps://sample/via-sim", device: nil, in: &ctx)
        #expect(try await arrival(of: "samplecaps://sample/via-sim", &ctx, svc) == "warm")
        let refused = await #expect(throws: XcdError.self) { _ = try await svc.routes.open(.url("nope://x"), OpenOptions(), in: &ctx) }
        #expect(refused?.code == .usage && refused?.next?.contains("sampleapp, SampleCaps") == true, "\(String(describing: refused))")
    }

    @Test(.timeLimit(.minutes(20))) func aLinkTheAppCrashesOnIsACrashWithItsReport() async throws {
        try await withInstalledApp { ctx, svc in
            let report = try await svc.routes.open(.route(name: "crash", values: [:]), OpenOptions(), in: &ctx)
            #expect(report.failure?.code == .appCrashed, "\(report.text)")
            #expect(report.failure?.message.hasPrefix("the link was sent, and the app crashed") == true)
            let crash = try #require(report.crash, "no crash report: \(report.text)")
            #expect(crash.processName == "SampleApp" && FileManager.default.fileExists(atPath: crash.path))
            #expect(report.appOutput?.contains { $0.contains("SampleApp crashed on a link") } == true)
            // The app is gone, so the same link sent cold must start it, and it crashes again.
            let cold = try await svc.routes.open(.route(name: "crash", values: [:]), OpenOptions(cold: true), in: &ctx)
            #expect(cold.app?.state == .startedByLink && cold.failure?.code == .appCrashed, "\(cold.text)")
        }
    }
}
