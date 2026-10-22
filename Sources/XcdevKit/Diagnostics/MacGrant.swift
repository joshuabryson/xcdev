import Foundation

/// The two grants `xcd doctor` can ask macOS for.
public enum MacGrantKind: String, Codable, Sendable {
    case accessibility, screenRecording

    public var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }

    /// The kind's pane in System Settings > Privacy & Security, as `open` takes it.
    public var paneURL: String {
        switch self {
        case .accessibility: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording: return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
    }

    /// The switch by hand: the `next:` a Mac `ui` command's `permission_missing` gives for this grant.
    func byHand(_ app: String) -> String {
        self == .accessibility ? MacPermissions.accessibilityNext(app) : MacPermissions.screenRecordingNext(app)
    }
}

/// What `xcd doctor --grant-…` did. A grant not given is the result's failure, `permission_missing`, so the JSON still
/// says how long it waited and whether the pane opened.
public struct DoctorGrantReport: Reportable {
    public let permission: MacGrantKind
    /// The app macOS gives the grant to.
    public let hostApp: String
    public let granted: Bool
    /// The switch was on before anything was asked: no prompt was shown.
    public let alreadyGranted: Bool
    public let paneOpened: Bool
    /// Seconds from the prompt to the grant, or to giving up.
    public let waited: Double

    /// The text renderer prints a failure's `next:` only, so a grant not given says its message here.
    public var text: String {
        if alreadyGranted { return "\(permission.title) is already granted to \(hostApp)" }
        guard granted else { return failure?.message ?? "" }
        let reopen = permission == .screenRecording ? " after quitting and reopening \(hostApp): macOS applies that grant at launch" : ""
        return "\(permission.title) granted to \(hostApp); run the command again" + reopen
    }

    /// For Screen Recording the poll may never see the switch: macOS applies that grant at launch, and the
    /// in-process poll of `CGPreflightScreenCaptureAccess()` is unmeasured, so the message says how to make it count.
    public var failure: XcdError? {
        guard !granted else { return nil }
        let limit = Int(DurationText.seconds(MacGrant.limit))
        let reopen = permission == .screenRecording
            ? "; if you turned it on, quit and reopen \(hostApp): macOS applies that grant at launch" : ""
        return XcdError(.permissionMissing, "\(hostApp) still has no \(permission.title) permission after \(limit) s" + reopen,
                        next: permission.byHand(hostApp))
    }
}

/// `xcd doctor --grant-accessibility` and `--grant-screen-recording`, at the user's word: the only code that shows the
/// system's permission prompt or opens the pane.
/// Not `Sendable`: it holds the Accessibility API, which lives inside one command.
public struct MacGrant {
    public static let limit: Duration = .seconds(60)
    /// The person may have dismissed the prompt by then; the pane opened later than at once does not cover the prompt.
    public static let paneAfter: Duration = .seconds(20)
    public static let interval: Duration = .seconds(1)

    let api: any AccessibilityAPI
    let hostApp: String
    let runner: any ProcessRunning
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void
    let progress: @Sendable (String) -> Void
    let hasSession: @Sendable () -> Bool

    public init(api: any AccessibilityAPI, hostApp: String, runner: any ProcessRunning, now: @escaping @Sendable () -> Date,
                sleep: @escaping @Sendable (Duration) async throws -> Void, progress: @escaping @Sendable (String) -> Void,
                hasSession: @escaping @Sendable () -> Bool = { MacScreenLock.hasWindowServerSession() }) {
        self.api = api
        self.hostApp = hostApp
        self.runner = runner
        self.now = now
        self.sleep = sleep
        self.progress = progress
        self.hasSession = hasSession
    }

    /// How the wait ended.
    struct Wait {
        var granted = false
        var paneOpened = false
        var paneTried = false
        var waited: Double = 0
    }

    public func run(_ kind: MacGrantKind) async throws -> DoctorGrantReport {
        guard hasSession() else {
            throw XcdError(.permissionMissing, "there is no window server session to show the \(kind.title) prompt in",
                           next: "at the Mac, " + kind.byHand(hostApp))
        }
        if isOn(kind) { return report(kind, Wait(granted: true), alreadyGranted: true) }
        progress("waiting for the \(kind.title) switch for \(hostApp) (every program started from it gets the grant)")
        let start = now()
        request(kind)
        let wait = try await waitForGrant(kind, since: start)
        return report(kind, wait)
    }

    func isOn(_ kind: MacGrantKind) -> Bool { kind == .accessibility ? api.isTrusted : api.screenCaptureAllowed }

    /// The system prompt. Its answer is the switch before the person acts, which `run` has just read.
    func request(_ kind: MacGrantKind) {
        _ = kind == .accessibility ? api.requestTrust() : api.requestScreenCapture()
    }

    /// Reads the switch every `interval` until it is on or `limit` has passed. When `paneAfter` has passed with it still
    /// off, opens the pane, once.
    func waitForGrant(_ kind: MacGrantKind, since start: Date) async throws -> Wait {
        var wait = Wait()
        while true {
            try await sleep(Self.interval)
            wait.waited = now().timeIntervalSince(start)
            if isOn(kind) {
                wait.granted = true
                return wait
            }
            if wait.waited >= DurationText.seconds(Self.limit) { return wait }
            if !wait.paneTried, wait.waited >= DurationText.seconds(Self.paneAfter) {
                wait.paneTried = true
                wait.paneOpened = await openPane(kind)
            }
        }
    }

    /// Opens the kind's pane. When `open` fails, a note says to open it by hand and the wait goes on: the prompt's own
    /// button opens it too.
    func openPane(_ kind: MacGrantKind) async -> Bool {
        let opened = try? await runner.run(Invocation("/usr/bin/open", [kind.paneURL], timeout: .seconds(10)))
        guard opened?.succeeded == true else {
            Notes.current?.add("System Settings did not open: open Privacy & Security > \(kind.title) in it by hand")
            return false
        }
        progress("opened System Settings > Privacy & Security > \(kind.title)")
        return true
    }

    func report(_ kind: MacGrantKind, _ wait: Wait, alreadyGranted: Bool = false) -> DoctorGrantReport {
        DoctorGrantReport(permission: kind, hostApp: hostApp, granted: wait.granted, alreadyGranted: alreadyGranted,
                          paneOpened: wait.paneOpened, waited: wait.waited)
    }
}

extension DoctorService {
    /// `xcd doctor --grant-accessibility` or `--grant-screen-recording`, with doctor's own Accessibility API, host app,
    /// clock, sleep, and progress. `hasSession` is for tests; the command passes nothing.
    public func grant(_ kind: MacGrantKind,
                      hasSession: @escaping @Sendable () -> Bool = { MacScreenLock.hasWindowServerSession() }) async throws -> DoctorGrantReport {
        let flow = MacGrant(api: accessibility(), hostApp: hostApp(), runner: runner, now: now, sleep: sleep, progress: progress,
                            hasSession: hasSession)
        return try await flow.run(kind)
    }
}
