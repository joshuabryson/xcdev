import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// A route's `expect`: what xcd looks for after a delivery, when it looks, and what it reports.
@Suite struct ArrivalCheckTests {
    let base = RouteServiceTests()
    var fake: FakeProcessRunner { base.fake }
    let checked = OpenRequest.route(name: "checked", values: ["id": "Milk"])
    static let missing = ArrivalSight.missing(onScreen: ["Welcome", "signIn"], away: nil)
    static let noRunner = XcdError(.runnerFailed, "the iphone UI runner did not start within 2m00s",
                                   next: "run `xcd doctor`; a simulator's first boot can take minutes on a busy Mac, so retrying may be enough",
                                   details: ["log: /w/runner.log"])

    /// A context with the sample app built and installed; `pids` are its running processes.
    func context(pids: [Int32] = []) throws -> WorktreeContext {
        let ctx = try base.context()
        try base.setUp(ctx, pids: pids)
        return ctx
    }

    func looker(_ answers: Result<ArrivalSight, XcdError>...) -> FakeArrival {
        FakeArrival(answers.isEmpty ? [.success(.found(seconds: 0.6))] : answers, runner: fake)
    }

    /// The index of the command that sent the link.
    var sent: Int? { fake.calls.firstIndex { $0.arguments.starts(with: ["simctl", "openurl"]) } }

    @Test func anElementThatAppearsIsReported() async throws {
        defer { base.worktree.remove() }
        var ctx = try context()
        let arrival = looker()
        let report = try await base.service(arrival: arrival).open(checked, OpenOptions(), in: &ctx)
        // xcd started the app, so there was nothing to look at before the link.
        let look = try #require(arrival.looks.first)
        #expect(arrival.looks.count == 1 && look.target == "label~Milk" && look.timeout == .seconds(10) && look.device == "iphone")
        #expect(look.commandsBefore > (try #require(sent)))
        #expect(report.check == OpenReport.Check(target: "label~Milk", outcome: .appeared, seconds: 0.6, reason: nil))
        #expect(report.failure == nil && report.text.contains("\ncheck: label~Milk appeared after 0.6s\n"))
    }

    /// `ui wait` returns at once for an element that is already there, whether or not the link did anything. So a
    /// link to a copy that is already up is preceded by one look.
    @Test func aLinkToARunningAppLooksBeforeItIsSent() async throws {
        defer { base.worktree.remove() }
        var ctx = try context(pids: [500])
        let arrival = looker(.success(Self.missing), .success(.found(seconds: 1.25)))
        let report = try await base.service(arrival: arrival).open(checked, OpenOptions(), in: &ctx)
        let link = try #require(sent)
        #expect(arrival.looks.map(\.timeout) == [.zero, .seconds(10)])
        #expect(arrival.looks.map { $0.commandsBefore > link } == [false, true])       // one before the link, one after
        #expect(report.check == OpenReport.Check(target: "label~Milk", outcome: .appeared, seconds: 1.25, reason: nil))
    }

    @Test func anElementThatWasAlreadyOnScreenProvesNothing() async throws {
        defer { base.worktree.remove() }
        var ctx = try context(pids: [500])
        let arrival = looker(.success(.found(seconds: 0)))
        let report = try await base.service(arrival: arrival).open(checked, OpenOptions(), in: &ctx)
        #expect(arrival.looks.count == 1 && base.steps == ["spawn", "openurl"])        // the link still goes out
        #expect(report.check == OpenReport.Check(target: "label~Milk", outcome: .inconclusive, seconds: nil,
                                                 reason: "label~Milk was already on screen"))
        #expect(report.failure == nil && report.text.hasSuffix("\ncheck: inconclusive (label~Milk was already on screen)"))
    }

    /// A look before the link that could not see the app tells nothing about what was on its screen. The runner does
    /// not read an app that is in the background, so its element can be there all along, and finding it at once
    /// afterwards would prove nothing.
    @Test func anAppInTheBackgroundBeforeTheLinkProvesNothingAfterIt() async throws {
        try await checkLookAfterABlindLook(before: .success(.missing(onScreen: [], away: "the app is in the background")),
                                           why: "the app is in the background")
    }

    @Test func aLookBeforeTheLinkThatCouldNotBeMadeProvesNothingAfterIt() async throws {
        try await checkLookAfterABlindLook(before: .failure(Self.noRunner), why: "the iphone UI runner did not start within 2m00s")
    }

    /// Two looks, the second finds the element at once: the check is inconclusive, and the command succeeds.
    func checkLookAfterABlindLook(before: Result<ArrivalSight, XcdError>, why: String) async throws {
        defer { base.worktree.remove() }
        var ctx = try context(pids: [500])
        let arrival = looker(before, .success(.found(seconds: 0)))
        let report = try await base.service(arrival: arrival).open(checked, OpenOptions(), in: &ctx)
        let link = try #require(sent)
        let reason = "xcd could not look before the link was sent (\(why)), so label~Milk may already have been on screen"
        #expect(arrival.looks.map(\.timeout) == [.zero, .seconds(10)])
        #expect(arrival.looks.map { $0.commandsBefore > link } == [false, true])       // one before the link, one after
        #expect(base.steps == ["spawn", "openurl"])
        #expect(report.check == OpenReport.Check(target: "label~Milk", outcome: .inconclusive, seconds: nil, reason: reason))
        #expect(report.failure == nil && report.text.hasSuffix("\ncheck: inconclusive (" + reason + ")"))
    }

    /// Not being able to look before does not excuse the element: if the look after misses it, that is today's failure.
    @Test func aLookBeforeThatCouldNotTellStillFailsWhenTheElementNeverShows() async throws {
        defer { base.worktree.remove() }
        var ctx = try context(pids: [500])
        let arrival = looker(.failure(Self.noRunner), .success(Self.missing))
        let report = try await base.service(arrival: arrival).open(checked, OpenOptions(), in: &ctx)
        #expect(arrival.looks.map(\.timeout) == [.zero, .seconds(10)])
        #expect(report.failure?.code == .waitTimeout)
        #expect(report.failure?.message == "the link was sent, but label~Milk did not appear within 10.0s")
        #expect(report.check == OpenReport.Check(target: "label~Milk", outcome: .missing, seconds: 10, reason: nil))
    }

    /// A restart clears the screen, so what shows up afterwards is the link's doing: no look before.
    @Test func anAppThatIsRestartedIsNotLookedAtFirst() async throws {
        defer { base.worktree.remove() }
        var ctx = try context(pids: [500])
        let arrival = looker()
        let report = try await base.service(arrival: arrival).open(checked, OpenOptions(preset: "fresh"), in: &ctx)
        #expect(arrival.looks.map(\.timeout) == [.seconds(10)] && report.check?.outcome == .appeared)
    }

    @Test func aLaunchRouteIsCheckedToo() async throws {
        defer { base.worktree.remove() }
        var ctx = try context(pids: [500])
        let arrival = looker()
        let report = try await base.service(arrival: arrival).open(.route(name: "tour", values: [:]), OpenOptions(), in: &ctx)
        #expect(arrival.looks.map(\.target) == ["id:tour"] && arrival.looks.map(\.timeout) == [.seconds(10)])
        #expect(report.check?.outcome == .appeared && report.app?.state == .restarted)
    }

    @Test func anElementThatNeverAppearsIsAWaitTimeout() async throws {
        defer { base.worktree.remove() }
        var ctx = try context()
        let report = try await base.service(arrival: looker(.success(Self.missing))).open(checked, OpenOptions(), in: &ctx)
        #expect(report.failure?.code == .waitTimeout && report.failure?.code.exitCode == 1)
        #expect(report.failure?.message == "the link was sent, but label~Milk did not appear within 10.0s")
        #expect(report.failure?.next == "on screen now: Welcome, signIn; run `xcd ui tree`")
        #expect(report.check == OpenReport.Check(target: "label~Milk", outcome: .missing, seconds: 10, reason: nil))
        #expect(report.text.contains("\ncheck: label~Milk did not appear within 10.0s\n"))
        #expect(report.app?.state == .started && report.linkSent == true)   // the device changed, and the report says how
    }

    /// An https link that the system gives to Safari leaves the app behind. That is how it is caught.
    @Test func aLinkThatOpenedSomewhereElseSaysSo() async throws {
        defer { base.worktree.remove() }
        var ctx = try context()
        let away = ArrivalSight.missing(onScreen: [], away: "the app is in the background")
        let svc = base.service(arrival: looker(.success(away)))
        let web = try await svc.open(.route(name: "article", values: [:]), OpenOptions(), in: &ctx)
        #expect(web.failure?.code == .waitTimeout && web.failure?.message == "the link was sent, but id:article did not appear within 10.0s")
        #expect(web.failure?.next == "the app is in the background: an https link opens in Safari unless the app's associated domains work on this simulator; see what is in front with `xcd ui tree --system`")
        #expect(web.check?.reason == "the app is in the background")
        #expect(web.text.contains("\ncheck: id:article did not appear within 10.0s (the app is in the background)\n"))
        let custom = try await svc.open(checked, OpenOptions(preset: "fresh"), in: &ctx)
        #expect(custom.failure?.next == "the app is in the background; see what is in front with `xcd ui tree --system`")
    }

    @Test func nothingOnScreenStillSaysWhatToRun() async throws {
        defer { base.worktree.remove() }
        var ctx = try context()
        let empty = ArrivalSight.missing(onScreen: [], away: nil)
        let report = try await base.service(arrival: looker(.success(empty))).open(checked, OpenOptions(), in: &ctx)
        #expect(report.failure?.next == "run `xcd ui tree` to see what is on screen")
    }

    /// The watch runs for its whole window whatever the check saw. A process that ends is a crash.
    @Test func aCrashWinsOverWhatTheCheckSaw() async throws {
        defer { base.worktree.remove() }
        var ctx = try context(pids: [46606])
        let ips = try base.writeCrashReport()
        let seen = looker(.success(Self.missing), .success(.found(seconds: 0.3)))
        let appeared = try await base.service(FakeProbe(runningChecks: 2), arrival: seen).open(checked, OpenOptions(), in: &ctx)
        #expect(appeared.failure?.code == .appCrashed && appeared.crash?.path == ips)
        #expect(appeared.check?.outcome == .appeared)                       // it did show, and then the app died
        let unseen = try await base.service(FakeProbe(runningChecks: 2), arrival: looker(.success(Self.missing)))
            .open(checked, OpenOptions(), in: &ctx)
        #expect(unseen.failure?.code == .appCrashed && unseen.check?.outcome == .missing)
    }

    /// A route with `expect` promises a check, so a runner that cannot run is a failure, not a skip. The link has
    /// gone out by then, the watch has run, and the message says so.
    @Test func aRunnerThatCannotRunIsLoud() async throws {
        defer { base.worktree.remove() }
        var ctx = try context(pids: [500])
        let said = Shared<[String]>([])
        let arrival = looker(.failure(Self.noRunner))
        let report = try await base.service(arrival: arrival, progress: { line in said.change { $0.append(line) } })
            .open(checked, OpenOptions(), in: &ctx)
        #expect(arrival.looks.count == 2 && base.steps == ["spawn", "openurl"])        // the look before failed too; the link still went
        #expect(said.value == ["delivered to dev.xcdev.SampleApp (pid 500); watching 2.0s for a crash"])
        #expect(report.failure?.code == .runnerFailed && report.failure?.code.exitCode == 3)
        #expect(report.failure?.message == "the link was sent, but the arrival check could not run: the iphone UI runner did not start within 2m00s")
        #expect(report.failure?.next == Self.noRunner.next && report.failure?.details == ["log: /w/runner.log"])
        #expect(report.check == OpenReport.Check(target: "label~Milk", outcome: .failed, seconds: nil,
                                                 reason: "the iphone UI runner did not start within 2m00s"))
        #expect(report.text.contains("\ncheck: could not run (the iphone UI runner did not start within 2m00s)"))
    }

    /// An app that was gone before its link could be sent has nothing to check.
    @Test func nothingIsLookedForWhenTheLinkWasNotSent() async throws {
        defer { base.worktree.remove() }
        var ctx = try context()
        let arrival = looker()
        let report = try await base.service(FakeProbe(runningChecks: 0), arrival: arrival).open(checked, OpenOptions(), in: &ctx)
        #expect(arrival.looks.isEmpty && report.check == nil && report.linkSent == false && report.failure?.code == .appCrashed)
    }

    /// UI driving is for iPhone and iPad simulators on iOS 17 or later. Elsewhere the check is skipped, and says why.
    @Test func theCheckIsSkippedWhereUIDrivingDoesNotWork() async throws {
        defer { base.worktree.remove() }
        var ctx = try context(pids: [500])
        let udid = try await base.clone(&ctx)
        ctx.state.devices["iphone"] = ProvisionedDevice(udid: udid, deviceType: "iPhone 15", deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-15",
                                                        runtime: "iOS 16.4", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-16-4")
        let arrival = looker()
        let svc = base.service(arrival: arrival)
        #expect(svc.arrivalUnavailable(on: "iphone", in: ctx) == "the UI runner needs iOS 17 or later; 'iphone' runs iOS 16.4")
        #expect(svc.arrivalUnavailable(on: "mac", in: ctx) == "the arrival check needs UI driving, which works on iPhone and iPad simulators only")
        ctx.state.devices["iphone"]?.runtimeIdentifier = "com.apple.CoreSimulator.SimRuntime.watchOS-27-0"
        ctx.state.devices["iphone"]?.runtime = "watchOS 27.0"
        #expect(svc.arrivalUnavailable(on: "iphone", in: ctx) == "UI driving supports iPhone and iPad simulators; 'iphone' runs watchOS 27.0")
        #expect(svc.arrivalPlan(try RouteResolver(config: ctx.config).resolve(checked), on: "iphone", in: ctx)
                == .skipped(target: "label~Milk", reason: "UI driving supports iPhone and iPad simulators; 'iphone' runs watchOS 27.0"))
        #expect(arrival.looks.isEmpty)
    }

    /// A link with no check that the system may have given to Safari: the result says that nothing looked.
    @Test func anUncheckedWebLinkIsNoted() async throws {
        defer { base.worktree.remove() }
        var ctx = try context(pids: [500])
        let svc = base.service()
        let note = "nothing checked where this link went: an https link opens in Safari unless the app's associated domains work on this simulator. Run `xcd ui wait <target>`, or give its route an `expect`"
        let web = try await svc.open(.route(name: "web", values: [:]), OpenOptions(), in: &ctx)
        #expect(web.note == note && web.text.hasSuffix("\nnote: " + note) && web.failure == nil)
        #expect(try await svc.open(.url("HTTPS://example.com/x"), OpenOptions(), in: &ctx).note == note)
        #expect(try await svc.open(.route(name: "item", values: ["id": "1"]), OpenOptions(), in: &ctx).note == nil)
        #expect(try await svc.open(.route(name: "article", values: [:]), OpenOptions(), in: &ctx).note == nil)       // it has a check
    }
}
