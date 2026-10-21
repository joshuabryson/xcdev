import Darwin
import Foundation

/// What a capture makes: the word for it in a media folder's file names, and its file's extension.
enum MediaKind: String {
    case screenshot, recording

    var ext: String { self == .screenshot ? "png" : "mp4" }
}

/// `xcd ui screenshot` and `xcd ui record`; on a Mac, of the app's main window.
public struct MediaService: Sendable {
    public let provisioner: DeviceProvisioner
    public let detached: any DetachedProcessLaunching
    /// Where a relative `--out` starts.
    public let currentDirectory: String
    public let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void
    /// How long `record start` waits for the recorder to print "Recording started".
    let startTimeout: Duration
    /// ScreenCaptureKit, for a Mac device's window.
    let capture: any WindowCapturing
    /// The host app's grants, read for each Mac capture.
    let permissions: @Sendable () -> MacPermissions
    /// The Accessibility API, for the title of a Mac app's main window; made fresh for each use, as it holds CF objects.
    let accessibility: @Sendable () -> any AccessibilityAPI
    /// Whether the Mac's screen is locked, which makes every window read meaningless.
    let screenLocked: @Sendable () -> Bool
    /// The xcd that runs `_record-window` for a Mac recording: this binary, unless a test names the built one.
    let xcdExecutable: String

    /// How long a stop waits for simctl to exit after SIGINT before killing it. On a freshly booted simulator simctl
    /// sometimes takes well over 10 s to exit even though the video is already complete (measured: exits after 1 to
    /// about 14 s, once past 15 s), and a SIGKILL there risks an incomplete file, so this is generous.
    public static let stopTimeout: Duration = .seconds(45)

    public init(provisioner: DeviceProvisioner, detached: any DetachedProcessLaunching, currentDirectory: String,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                startTimeout: Duration = .seconds(10), capture: any WindowCapturing = ScreenCaptureKitCapture(),
                permissions: @escaping @Sendable () -> MacPermissions = { MacPermissions.read(api: SystemAccessibility(), hostApp: MacHostApp.live()) },
                accessibility: @escaping @Sendable () -> any AccessibilityAPI = { SystemAccessibility() },
                screenLocked: @escaping @Sendable () -> Bool = { MacScreenLock.isLocked() },
                xcdExecutable: String = Bundle.main.executablePath ?? CommandLine.arguments[0]) {
        self.provisioner = provisioner
        self.detached = detached
        self.currentDirectory = currentDirectory
        self.now = now
        self.sleep = sleep
        self.startTimeout = startTimeout
        self.capture = capture
        self.permissions = permissions
        self.accessibility = accessibility
        self.screenLocked = screenLocked
        self.xcdExecutable = xcdExecutable
    }

    public func screenshot(device requested: String?, out: String?, in ctx: inout WorktreeContext) async throws -> ScreenshotReport {
        let name = try provisioner.deviceName(requested, config: ctx.config)
        if ctx.config.allDevices[name]?.isMac == true { return try await macScreenshot(name, out: out, in: ctx) }
        let (device, _) = try await provisioner.boot(name, in: &ctx)
        let target = try destination(out, device: name, kind: .screenshot, in: ctx)
        let path = target.path
        let simctl = provisioner.simctl(for: ctx)
        try await simctl.screenshot(udid: device.udid, path: path)
        let size = PNGInfo.size(of: path)
        let types = (try? await simctl.catalog())?.deviceTypes ?? []
        let bundle = types.first { $0.identifier == device.deviceTypeIdentifier }?.bundlePath
        return ScreenshotReport(device: name, udid: device.udid, path: path, width: size?.width, height: size?.height,
                                scale: bundle.flatMap(DeviceTypeProfile.scale(bundlePath:)), worktree: ctx.state.name,
                                gitignoreAdded: target.gitignoreAdded, gitignoreWarning: target.gitignoreWarning,
                                mainCheckout: ctx.location.projectRoot)
    }

    public func startRecording(device requested: String?, out: String?, in ctx: inout WorktreeContext) async throws -> RecordingReport {
        let name = try provisioner.deviceName(requested, config: ctx.config)
        let file = ctx.paths.recordingFile(device: name)
        if let existing = Recordings.load(file) {
            if detached.inspector.isRunning(existing.process, marker: existing.marker) {
                throw XcdError(.usage, "\(name) is already recording to \(existing.path)",
                               next: "stop it first with `xcd ui record stop --device \(name)`")
            }
            try? FileManager.default.removeItem(atPath: file)        // its recording ended without xcd
        }
        if ctx.config.allDevices[name]?.isMac == true { return try await macRecording(name, file: file, out: out, in: ctx) }
        let (device, _) = try await provisioner.boot(name, in: &ctx)
        let target = try destination(out, device: name, kind: .recording, in: ctx)
        let log = ctx.paths.recordingLog(device: name)
        let offset = (try? Data(contentsOf: URL(fileURLWithPath: log)))?.count ?? 0
        let process = try detached.start(provisioner.simctl(for: ctx).recordVideoInvocation(udid: device.udid, path: target.path), log: log)
        try await confirm(RecordingRecord(device: name, udid: device.udid, path: target.path, log: log, process: process, startedAt: now()),
                          file: file, logOffset: offset)
        return started(name, udid: device.udid, at: target, in: ctx)
    }

    /// Saves a recorder's record, then waits until it prints "Recording started" past `logOffset`. The record is saved
    /// first, so a recorder xcd can no longer see is never left running; one whose record can't be saved, or that never
    /// starts recording, is stopped.
    func confirm(_ record: RecordingRecord, file: String, logOffset offset: Int) async throws {
        do {
            try Recordings.save(record, to: file)
        } catch {
            _ = await detached.stop(record.process, marker: record.marker, signal: SIGINT, timeout: Self.stopTimeout)
            throw error
        }
        do {
            try await waitUntilRecording(record, logOffset: offset)
        } catch {
            _ = await Recordings.stop(record, file: file, detached: detached, now: now())
            throw error
        }
    }

    /// The report of a recording that has started.
    func started(_ name: String, udid: String?, at target: Destination, in ctx: WorktreeContext) -> RecordingReport {
        RecordingReport(action: .started, device: name, udid: udid, path: target.path, seconds: nil, bytes: nil,
                        outcome: nil, limit: DurationText.format(ctx.config.maxRecording), worktree: ctx.state.name,
                        gitignoreAdded: target.gitignoreAdded, gitignoreWarning: target.gitignoreWarning,
                        mainCheckout: ctx.location.projectRoot)
    }

    public func stopRecording(device requested: String?, in ctx: WorktreeContext) async throws -> RecordingReport {
        let name = try provisioner.deviceName(requested, config: ctx.config)
        let file = ctx.paths.recordingFile(device: name)
        guard let record = Recordings.load(file) else {
            return RecordingReport(action: .notRecording, device: name, udid: nil, path: nil, seconds: nil, bytes: nil,
                                   outcome: nil, limit: nil, worktree: ctx.state.name)
        }
        let stop = await Recordings.stop(record, file: file, detached: detached, now: now())
        return RecordingReport(action: .stopped, device: name, udid: record.udid, path: record.path, seconds: stop.seconds,
                               bytes: stop.bytes, outcome: stop.outcome, limit: nil, worktree: ctx.state.name)
    }

    /// Stops this worktree's recordings that have run longer than `ui.record.maxDuration`.
    public func stopOverdue(in ctx: WorktreeContext) async -> [RecordingStop] {
        let limit = DurationText.seconds(ctx.config.maxRecording)
        var stops: [RecordingStop] = []
        for file in ctx.paths.recordingFiles {
            guard let record = Recordings.load(file), now().timeIntervalSince(record.startedAt) > limit else { continue }
            stops.append(await Recordings.stop(record, file: file, detached: detached, now: now()))
        }
        return stops
    }

    /// Where a capture goes, and what happened to `.gitignore` getting there.
    struct Destination {
        let path: String
        var gitignoreAdded: String?
        var gitignoreWarning: String?
    }

    /// `--out` against the current directory (it must not exist; its folder is created), or a new file in the media
    /// folder, which is made git-ignored (a `.gitignore` that can't be written is a warning, not a failure).
    func destination(_ out: String?, device: String, kind: MediaKind, in ctx: WorktreeContext) throws -> Destination {
        guard let out else {
            let folder = MediaFolder.resolve(template: ctx.config.mediaDirTemplate, projectRoot: ctx.location.projectRoot,
                                             worktreeRoot: ctx.location.worktreeRoot, worktreeName: ctx.state.name, device: device)
            var added: String?
            var warning: String?
            do {
                added = try folder.ensureIgnored()
            } catch {
                warning = "could not add \(folder.ignoreEntry ?? "an entry") to .gitignore: \(error.localizedDescription)"
            }
            return Destination(path: folder.newFile(device: device, kind: kind.rawValue, ext: kind.ext, now: now()),
                               gitignoreAdded: added, gitignoreWarning: warning)
        }
        let expanded = (out as NSString).expandingTildeInPath
        let path = ((expanded.hasPrefix("/") ? expanded : currentDirectory + "/" + expanded) as NSString).standardizingPath
        guard !FileManager.default.fileExists(atPath: path) else {
            throw XcdError(.usage, "\(path) already exists", next: "pick another --out, or delete it first")
        }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return Destination(path: path)
    }

    /// simctl prints "Recording started" once it is writing frames, and so does the Mac's window
    /// recorder. Polls every 100ms, counted in attempts rather than clock time so tests with an instant `sleep` don't spin.
    func waitUntilRecording(_ record: RecordingRecord, logOffset: Int) async throws {
        let attempts = max(1, Int((DurationText.seconds(startTimeout) * 10).rounded()))
        for _ in 0..<attempts {
            if Self.text(of: record.log, from: logOffset).contains("Recording started") { return }
            guard detached.inspector.isRunning(record.process) else {
                throw XcdError(.simulatorFailed, "\(record.recorder == nil ? "simctl" : "the window recorder") stopped before the recording started",
                               next: "run `xcd doctor`", details: ["log: \(record.log)"] + Self.tail(record.log, from: logOffset))
            }
            try await sleep(.milliseconds(100))
        }
        throw XcdError(.simulatorFailed, "the recording didn't start within \(DurationText.format(startTimeout))",
                       next: "run `xcd doctor`", details: ["log: \(record.log)"] + Self.tail(record.log, from: logOffset))
    }

    static func text(of log: String, from offset: Int) -> String {
        guard let data = FileManager.default.contents(atPath: log), data.count >= offset else { return "" }
        return String(decoding: data.dropFirst(offset), as: UTF8.self)
    }

    static func tail(_ log: String, from offset: Int) -> [String] {
        text(of: log, from: offset).split(separator: "\n").suffix(20).map(String.init)
    }
}

/// A Mac device's captures are of the app's main window through ScreenCaptureKit, hidden or covered. The recording is
/// `xcd _record-window`, started and stopped as simctl's is, with its own marker.
extension MediaService {
    func macScreenshot(_ name: String, out: String?, in ctx: WorktreeContext) async throws -> ScreenshotReport {
        let window = try await macWindow(name, in: ctx)
        let target = try destination(out, device: name, kind: .screenshot, in: ctx)
        let info = try await capture.screenshot(window, to: target.path)
        return ScreenshotReport(device: name, udid: nil, path: target.path, width: info.width, height: info.height, scale: info.scale,
                                worktree: ctx.state.name, gitignoreAdded: target.gitignoreAdded, gitignoreWarning: target.gitignoreWarning,
                                mainCheckout: ctx.location.projectRoot)
    }

    func macRecording(_ name: String, file: String, out: String?, in ctx: WorktreeContext) async throws -> RecordingReport {
        let window = try await macWindow(name, in: ctx)
        let target = try destination(out, device: name, kind: .recording, in: ctx)
        let log = ctx.paths.recordingLog(device: name)
        let offset = (try? Data(contentsOf: URL(fileURLWithPath: log)))?.count ?? 0
        let scale = accessibility().screenScale(containing: window.frame)
        let arguments = [MacWindowRecorder.marker, "--window", String(window.id), "--out", target.path, "--scale", String(scale)]
        let process = try detached.start(Invocation(xcdExecutable, arguments), log: log)
        try await confirm(RecordingRecord(device: name, udid: "mac", path: target.path, log: log, process: process, startedAt: now(),
                                          recorder: MacWindowRecorder.marker), file: file, logOffset: offset)
        return started(name, udid: nil, at: target, in: ctx)
    }

    /// The lock first (a locked screen's windows read as garbage, granted or not), then the Screen Recording grant, the
    /// app's process, and its window: the one ScreenCaptureKit lists under the title of the window the tree calls main.
    func macWindow(_ name: String, in ctx: WorktreeContext) async throws -> CapturedWindow {
        if screenLocked() { throw MacScreenLock.refusal }
        try permissions().require(screenRecording: true)
        let pid = try await MacAppLookup.runningPid(device: name, runner: provisioner.runner, in: ctx)
        guard let title = try mainTitle(pid: pid), let window = try await capture.mainWindow(pid: pid, title: title) else {
            throw XcdError(.elementNotFound, "the app has no window to capture",
                           next: "open one with `xcd open <route>`, or watch the app with `xcd launch --device \(name) --show`")
        }
        return window
    }

    /// The title of the app's main window as `xcd ui tree` picks it (the one with content, past an empty twin), or nil
    /// when it has no window. A read the app does not answer is `runner_failed`, as in a `ui` command.
    func mainTitle(pid: Int32) throws -> String? {
        let api = accessibility()
        do {
            return try MacSnapshot(api: api).mainTitle(app: api.application(pid: pid))
        } catch let error as MacAXError {
            let failure = MacDriver.failure(for: error, during: "reading the main window's title")
            throw XcdError(.runnerFailed, failure.message, next: "ask the user whether a system prompt is up, then run the command again",
                           details: failure.issues)
        }
    }
}
