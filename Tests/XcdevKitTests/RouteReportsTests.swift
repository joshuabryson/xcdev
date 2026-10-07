import Foundation
import Testing
@testable import XcdevKit

@Suite struct RouteReportsTests {
    func config() throws -> XcdevConfig { try ConfigLoader.parse(main: DeepLinksConfigTests.example) }

    @Test func theListShowsEveryRouteWithItsParameters() throws {
        #expect(RouteListReport(config: try config(), worktree: "feat").text == """
        item  url  Open one saved link
          id   required  The link's UUID
          tab  optional  notes|preview  Which tab to show
        onboarding  launch  preset=fresh-install  Start at an onboarding step
          step  default=1  1 to 4
        seeded-album  run  Create a sample album and open it
        settings/appearance  url  Appearance settings
        4 routes  open one with `xcd open <route> [name=value …]`
        """)
    }

    @Test func anEmptyListSaysHowToAddRoutes() throws {
        let report = RouteListReport(config: try ConfigLoader.parse(main: "version: 1\nproject: A.xcodeproj\n"), worktree: "feat")
        #expect(report.text == "no routes  add them under `deeplinks:` in .xcdev.yml (`xcd config explain deeplinks`)")
        #expect(report.routes.isEmpty && report.failure == nil)
    }

    @Test func aRawParameterAndASingleRouteReadNaturally() throws {
        let yaml = """
        version: 1
        project: A.xcodeproj
        deeplinks:
          routes:
            page: { description: "A page", url: "myapp://x/{path}", params: { path: { raw: true } } }
        """
        #expect(RouteListReport(config: try ConfigLoader.parse(main: yaml), worktree: "feat").text == """
        page  url  A page
          path  required  raw
        1 route  open one with `xcd open <route> [name=value …]`
        """)
    }

    @Test func theListAsJSON() throws {
        let json = Renderer.report(RouteListReport(config: try config(), worktree: "feat"), command: "open", format: .json)
        let data = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let routes = try #require((data["data"] as? [String: Any])?["routes"] as? [[String: Any]])
        #expect(routes.map { $0["name"] as? String } == ["item", "onboarding", "seeded-album", "settings/appearance"])
        #expect(routes.map { $0["kind"] as? String } == ["url", "launch", "run", "url"])
        #expect(routes[0]["url"] as? String == "{base}/item?id={id}&tab={tab}" && routes[0]["expect"] as? String == "id:item-detail")
        #expect((routes[1]["launch"] as? [String: Any])?["args"] as? [String] == ["-startRoute", "onboarding/{step}"])
        #expect(routes[1]["preset"] as? String == "fresh-install" && routes[2]["run"] as? String == "./scripts/open-album.sh")
        let params = try #require(routes[0]["params"] as? [[String: Any]])
        #expect(params.map { $0["name"] as? String } == ["id", "tab"])
        #expect(params[0]["required"] as? Bool == true && params[0]["raw"] as? Bool == false)
        #expect(params[1]["values"] as? [String] == ["notes", "preview"] && params[1]["required"] as? Bool == false)
        let step = try #require((routes[1]["params"] as? [[String: Any]])?.first)
        #expect(step["default"] as? String == "1")
        #expect(data["worktree"] as? String == "feat")
    }

    func report(_ name: String, _ values: [String: String] = [:], dryRun: Bool = false) throws -> OpenReport {
        let config = try config()
        let route = try RouteResolver(config: config).resolve(.route(name: name, values: values))
        let plan = try OpenPlan(route, OpenOptions(), onMac: false, config: config)
        return plan.report(device: dryRun ? "iphone" : "iphone (iPhone 18 Pro, iOS 27.0)", dryRun: dryRun, worktree: "feat")
    }

    @Test func aDryRunSaysWhatWouldBeSent() throws {
        #expect(try report("item", ["id": "3F2A"], dryRun: true).text == """
        would open item  device=iphone
        url: sampleapp://sampleapp/item?id=3F2A
        """)
        #expect(try report("onboarding", ["step": "2"], dryRun: true).text == """
        would open onboarding  device=iphone
        args: -resetOnboarding YES -startRoute onboarding/2
        env: API_ENV=staging
        preset: fresh-install
        """)
    }

    /// A script route's dry run names the variables it would get and the ones left unset.
    @Test func aDryRunOfAScriptRoute() throws {
        let yaml = """
        version: 1
        project: A.xcodeproj
        deeplinks:
          routes:
            seeded:
              description: "Seed"
              run: ./seed.sh
              params: { title: {}, note: { optional: true } }
        """
        let config = try ConfigLoader.parse(main: yaml)
        let route = try RouteResolver(config: config).resolve(.route(name: "seeded", values: ["title": "two words"]))
        let report = try OpenPlan(route, OpenOptions(dryRun: true), onMac: false, config: config)
            .report(device: "iphone", dryRun: true, worktree: "feat")
        #expect(report.text == """
        would open seeded  device=iphone
        script: ./seed.sh
        env: XCD_PARAM_TITLE='two words' XCD_ROUTE=seeded
        unset: XCD_PARAM_NOTE
        """)
        #expect(report.unset == ["XCD_PARAM_NOTE"] && report.failure == nil)
    }

    /// The `--preset` and `--cold` rules for a link, decided before a device is touched.
    @Test func presetAndColdAreAppliedToALink() throws {
        let config = try config()
        let item = try RouteResolver(config: config).resolve(.route(name: "item", values: ["id": "7"]))
        let preset = try OpenPlan(item, OpenOptions(preset: "fresh-install"), onMac: false, config: config)
        #expect(preset.preset == "fresh-install" && !preset.cold)
        #expect(preset.launch == LaunchPlan(arguments: ["-resetOnboarding", "YES"], environment: ["API_ENV": "staging"],
                                            crashWindow: CrashWindows.started))
        #expect(try OpenPlan(item, OpenOptions(cold: true), onMac: false, config: config).cold)
        #expect(try OpenPlan(.direct("myapp://x"), OpenOptions(cold: true), onMac: false, config: config).cold)
        // The system starts the app on a simulator, so a preset's launch arguments cannot be passed. A Mac can.
        let both = OpenOptions(preset: "fresh-install", cold: true)
        let refused = #expect(throws: XcdError.self) { _ = try OpenPlan(item, both, onMac: false, config: config) }
        #expect(refused?.code == .usage && refused?.next == "drop --cold or --preset")
        let mac = try OpenPlan(item, both, onMac: true, config: config)
        #expect(mac.cold && mac.preset == "fresh-install" && mac.launch.arguments == ["-resetOnboarding", "YES"])
        let unknown = #expect(throws: XcdError.self) { _ = try OpenPlan(item, OpenOptions(preset: "nope"), onMac: false, config: config) }
        #expect(unknown?.code == .usage)
    }

    /// A launch route always starts the app, so `--cold` changes nothing. A script route takes neither flag.
    @Test func aLaunchRouteIgnoresColdAndAScriptRouteTakesNeitherFlag() throws {
        let config = try config()
        let resolver = RouteResolver(config: config)
        let onboarding = try resolver.resolve(.route(name: "onboarding", values: [:]))
        let launch = try OpenPlan(onboarding, OpenOptions(cold: true), onMac: false, config: config)
        #expect(!launch.cold && launch.preset == "fresh-install")
        #expect(launch.launch.arguments == ["-resetOnboarding", "YES", "-startRoute", "onboarding/1"])
        let script = try resolver.resolve(.route(name: "seeded-album", values: [:]))
        func refusal(_ options: OpenOptions) -> XcdError? {
            #expect(throws: XcdError.self) { _ = try OpenPlan(script, options, onMac: false, config: config) }
        }
        #expect(refusal(OpenOptions(preset: "fresh-install"))?.message.hasPrefix("--preset does not apply to a script route") == true)
        #expect(refusal(OpenOptions(cold: true))?.message.hasPrefix("--cold does not apply to a script route") == true)
        // With both flags the first one named is --preset.
        let first = refusal(OpenOptions(preset: "fresh-install", cold: true))
        #expect(first?.code == .usage && first?.next == "run `xcd open seeded-album` without --preset")
    }

    @Test func aResultSaysWhatHappenedToTheApp() throws {
        var report = try report("item", ["id": "3F2A", "tab": "notes"])
        report.app = OpenReport.App(state: "running", pid: 4312, bundleId: "dev.x.App", log: nil)
        report.check = OpenReport.Check(target: "id:item-detail", outcome: "appeared", seconds: 0.6, reason: nil)
        #expect(report.text == """
        opened item  device=iphone (iPhone 18 Pro, iOS 27.0)  app=running  pid=4312
        url: sampleapp://sampleapp/item?id=3F2A&tab=notes
        check: id:item-detail appeared after 0.6s
        """)
        report.check = OpenReport.Check(target: "id:item-detail", outcome: "skipped", seconds: nil, reason: "not an iPhone or iPad")
        report.app = OpenReport.App(state: "started", pid: 9, bundleId: "dev.x.App", log: "/w/app.log")
        #expect(report.text.hasSuffix("check: skipped (not an iPhone or iPad)\nlog: /w/app.log"))
        #expect(report.failure == nil)
    }

    @Test func aURLGivenDirectlyIsCalledALink() throws {
        var report = OpenReport(.direct("myapp://x"), device: "iphone (iPhone 18 Pro, iOS 27.0)", dryRun: false, worktree: "feat")
        report.app = OpenReport.App(state: "started-by-link", pid: 7, bundleId: "dev.x.App", log: nil)
        #expect(report.text == "opened link  device=iphone (iPhone 18 Pro, iOS 27.0)  app=started-by-link  pid=7\nurl: myapp://x")
        #expect(report.route == nil && report.kind == "url")
    }

    @Test func aCrashIsAFailureThatSaysTheLinkWasSent() throws {
        var report = try report("item", ["id": "1"])
        report.app = OpenReport.App(state: "running", pid: 4312, bundleId: "dev.x.App", log: "/w/app.log")
        report.exitedAfter = 0.25
        report.crash = CrashReport(path: "/r/App.ips", processName: "App", pid: 4312, bundleId: "dev.x.App",
                                   exception: "EXC_BREAKPOINT (SIGTRAP)", termination: "Trace/BPT trap: 5", frames: ["App  handle(_:)"])
        report.appOutput = ["Fatal error: boom"]
        #expect(report.text == """
        opened item  device=iphone (iPhone 18 Pro, iOS 27.0)  app=running  pid=4312
        url: sampleapp://sampleapp/item?id=1
        app crashed 0.2s later
        crash: EXC_BREAKPOINT (SIGTRAP), Trace/BPT trap: 5
          App  handle(_:)
        app output (last lines):
          Fatal error: boom
        report: /r/App.ips
        log: /w/app.log
        """)
        #expect(report.failure?.code == .appCrashed)
        #expect(report.failure?.message == "the link was sent, and the app crashed 0.2s later")
        report.crash = nil
        #expect(report.failure?.message == "the link was sent, and the app exited 0.2s later without a crash report")
        #expect(report.text.contains("\napp exited 0.2s later (no crash report found)\n"))
        var launched = try self.report("onboarding")
        launched.exitedAfter = 1
        #expect(launched.failure?.message == "the app was started with the route's arguments, and the app exited 1.0s later without a crash report")
    }

    @Test func aResultAsJSON() throws {
        var report = try report("item", ["id": "1"])
        report.app = OpenReport.App(state: "running", pid: 4312, bundleId: "dev.x.App", log: nil)
        let json = Renderer.report(report, command: "open", format: .json)
        #expect(json == #"{"command":"open","data":{"app":{"bundleId":"dev.x.App","pid":4312,"state":"running"},"device":"iphone (iPhone 18 Pro, iOS 27.0)","dryRun":false,"kind":"url","route":"item","url":"sampleapp://sampleapp/item?id=1","worktree":"feat"},"ok":true,"worktree":"feat"}"#)
    }
}
