import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd doctor --grant-accessibility` and `--grant-screen-recording`: the prompt, a read once a second for up to 60 s,
/// the pane once at 20 s, and a report. Time is a clock that
/// the flow's own sleeps move on, so a minute of waiting takes no time.
@Suite struct DoctorGrantTests {
    static let start = Date(timeIntervalSince1970: 1_000_000)
    let fake = FakeProcessRunner()
    let clock = Shared(DoctorGrantTests.start)
    let lines = Shared<[String]>([])
    let sleeps = Counter()
    /// Seconds after the start at which `open` was run.
    let opens = Shared<[Double]>([])

    /// Both grants as given; with `afterReads`, they come on at that read after a prompt, as when the person turns the switch.
    func api(afterReads: Int? = nil, trusted: Bool = false, capture: Bool = false) -> FakeAccessibility {
        let api = FakeAccessibility(app: FakeApp(windows: []))
        api.setTrusted(trusted, capture: capture)
        api.grantAfterReads = afterReads
        return api
    }

    /// The flow on `api` for the host app "iTerm", with the fake clock, `open` stubbed, and a session unless told otherwise.
    func grant(_ api: FakeAccessibility, session: Bool = true) -> MacGrant {
        let clock = clock, lines = lines, sleeps = sleeps, opens = opens
        fake.stub(["open"]) { _ in
            opens.change { $0.append(clock.value.timeIntervalSince(DoctorGrantTests.start)) }
            return ProcessOutput()
        }
        return MacGrant(api: api, hostApp: "iTerm", runner: fake, now: { clock.value },
                        sleep: { duration in
                            sleeps.increment()
                            clock.change { $0 += DurationText.seconds(duration) }
                        },
                        progress: { line in lines.change { $0.append(line) } }, hasSession: { session })
    }

    /// When the switch is already on, nothing is asked and nothing waits.
    @Test func anExistingGrantShowsNoPrompt() async throws {
        let on = api(trusted: true, capture: true)
        let report = try await grant(on).run(.accessibility)
        #expect(report.alreadyGranted && report.granted && report.failure == nil && report.waited == 0)
        #expect(report.text == "Accessibility is already granted to iTerm")
        let screen = try await grant(on).run(.screenRecording)
        #expect(screen.text == "Screen Recording is already granted to iTerm")
        #expect(on.requests.isEmpty && sleeps.value == 0 && fake.calls.isEmpty && lines.value.isEmpty)
    }

    @Test func aGrantGivenAfterThreeReadsIsReportedWithTheWait() async throws {
        let off = api(afterReads: 3)
        let report = try await grant(off).run(.accessibility)
        #expect(report.granted && !report.alreadyGranted && !report.paneOpened && report.waited == 3)
        #expect(off.requests == ["trust"] && off.reads == 3 && sleeps.value == 3 && fake.calls.isEmpty)
        #expect(report.failure == nil && report.text == "Accessibility granted to iTerm; run the command again")
    }

    /// Nobody turns the switch on. The pane opens once at 20 s and the wait ends at 60 s.
    @Test func aGrantNeverGivenOpensThePaneOnceAndStopsAtSixtySeconds() async throws {
        let report = try await grant(api()).run(.accessibility)
        #expect(!report.granted && report.paneOpened && report.waited == 60 && sleeps.value == 60)
        #expect(opens.value == [20] && fake.calls.map(\.arguments) == [[MacGrantKind.accessibility.paneURL]])
        let failure = try #require(report.failure)
        #expect(failure.code == .permissionMissing && failure.code.exitCode == 3)
        #expect(failure.message == "iTerm still has no Accessibility permission after 60 s")
        #expect(failure.next == MacPermissions.accessibilityNext("iTerm"))
        #expect(Renderer.report(report, command: "doctor", format: .text, notes: [])
            == "iTerm still has no Accessibility permission after 60 s\nnext: \(MacPermissions.accessibilityNext("iTerm"))")
        let json = Renderer.report(report, command: "doctor", format: .json, notes: [])
        #expect(json.contains(#""ok":false"#) && json.contains(#""code":"permission_missing""#) && json.contains(#""paneOpened":true"#))
    }

    @Test func screenRecordingUsesItsOwnPaneRequestAndReopenAdvice() async throws {
        let given = api(afterReads: 2, trusted: true)
        let report = try await grant(given).run(.screenRecording)
        #expect(given.requests == ["screen"] && report.granted && report.waited == 2)
        #expect(report.text == "Screen Recording granted to iTerm; run the command again after quitting and reopening iTerm: "
            + "macOS applies that grant at launch")
        let never = try await grant(api(trusted: true)).run(.screenRecording)
        #expect(never.failure?.message == "iTerm still has no Screen Recording permission after 60 s; if you turned it on, "
            + "quit and reopen iTerm: macOS applies that grant at launch")
        #expect(never.failure?.next == MacPermissions.screenRecordingNext("iTerm"))
        #expect(fake.calls.map(\.arguments) == [["x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]])
    }

    /// Over ssh there is nowhere to show the prompt: refused before any read, prompt, or wait.
    @Test func noWindowServerSessionIsRefusedBeforeAnyPrompt() async throws {
        let off = api()
        let error = await #expect(throws: XcdError.self) { _ = try await grant(off, session: false).run(.accessibility) }
        #expect(error?.code == .permissionMissing && error?.message == "there is no window server session to show the Accessibility prompt in")
        #expect(error?.next == "at the Mac, " + MacPermissions.accessibilityNext("iTerm"))
        #expect(off.requests.isEmpty && sleeps.value == 0 && fake.calls.isEmpty && lines.value.isEmpty)
    }

    @Test func progressNamesTheSwitchAndTheReach() async throws {
        _ = try await grant(api()).run(.accessibility)
        #expect(lines.value == ["waiting for the Accessibility switch for iTerm (every program started from it gets the grant)",
                                "opened System Settings > Privacy & Security > Accessibility"])
    }

    /// A pane that will not open is a note; the wait goes on, and `open` is not tried again every second.
    @Test func aPaneThatWillNotOpenIsANoteAndIsNotRetried() async throws {
        let flow = grant(api())
        fake.stub(["open"], exitCode: 1, stderr: "LSOpenURLsWithRole() failed")
        let notes = Notes()
        let report = try await Notes.$current.withValue(notes) { try await flow.run(.accessibility) }
        #expect(!report.paneOpened && report.waited == 60 && fake.calls.count == 1)
        #expect(notes.all == ["System Settings did not open: open Privacy & Security > Accessibility in it by hand"])
        #expect(lines.value.count == 1)
    }

    /// `xcd doctor --grant-accessibility` runs the flow with doctor's own Accessibility, host app, clock, and progress.
    @Test func doctorRunsTheFlowWithItsOwnAccessibilityHostClockAndProgress() async throws {
        let given = api(afterReads: 1)
        let clock = clock, lines = lines
        let service = DoctorService(runner: fake, globalPaths: GlobalPaths(base: "/nonexistent/xcdev"),
                                    discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []), now: { clock.value },
                                    accessibility: { given }, hostApp: { "iTerm" },
                                    sleep: { duration in clock.change { $0 += DurationText.seconds(duration) } },
                                    progress: { line in lines.change { $0.append(line) } })
        let report = try await service.grant(.accessibility, hasSession: { true })
        #expect(report.granted && report.waited == 1 && given.requests == ["trust"])
        #expect(report.text == "Accessibility granted to iTerm; run the command again")
        #expect(lines.value == ["waiting for the Accessibility switch for iTerm (every program started from it gets the grant)"])
    }
}
