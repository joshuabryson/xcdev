import Darwin
import Foundation

/// `xcd ui screenshot` and `xcd ui record`.
public struct MediaService: Sendable {
    public let provisioner: DeviceProvisioner
    public let detached: any DetachedProcessLaunching
    /// Where a relative `--out` starts.
    public let currentDirectory: String
    public let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void
    /// How long `record start` waits for simctl to print "Recording started".
    let startTimeout: Duration

    /// How long a stop waits for simctl to finish the video before killing it.
    public static let stopTimeout: Duration = .seconds(15)

    public init(provisioner: DeviceProvisioner, detached: any DetachedProcessLaunching, currentDirectory: String,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                startTimeout: Duration = .seconds(10)) {
        self.provisioner = provisioner
        self.detached = detached
        self.currentDirectory = currentDirectory
        self.now = now
        self.sleep = sleep
        self.startTimeout = startTimeout
    }

    public func screenshot(device requested: String?, out: String?, in ctx: inout WorktreeContext) async throws -> ScreenshotReport {
        let name = try provisioner.deviceName(requested, config: ctx.config)
        let (device, _) = try await provisioner.boot(name, in: &ctx)
        let path = try destination(out, device: name, kind: "screenshot", ext: "png", in: ctx)
        let simctl = provisioner.simctl(for: ctx)
        try await simctl.screenshot(udid: device.udid, path: path)
        let size = PNGInfo.size(of: path)
        let types = (try? await simctl.catalog())?.deviceTypes ?? []
        let bundle = types.first { $0.identifier == device.deviceTypeIdentifier }?.bundlePath
        return ScreenshotReport(device: name, udid: device.udid, path: path, width: size?.width, height: size?.height,
                                scale: bundle.flatMap(DeviceTypeProfile.scale(bundlePath:)), worktree: ctx.state.name)
    }

    public func startRecording(device requested: String?, out: String?, in ctx: inout WorktreeContext) async throws -> RecordingReport {
        let name = try provisioner.deviceName(requested, config: ctx.config)
        let file = ctx.paths.recordingFile(device: name)
        if let existing = Recordings.load(file) {
            if detached.inspector.isRunning(existing.process, marker: Recordings.marker) {
                throw XcdError(.usage, "\(name) is already recording to \(existing.path)",
                               next: "stop it first with `xcd ui record stop --device \(name)`")
            }
            try? FileManager.default.removeItem(atPath: file)        // its recording ended without xcd
        }
        let (device, _) = try await provisioner.boot(name, in: &ctx)
        let path = try destination(out, device: name, kind: "recording", ext: "mp4", in: ctx)
        let log = ctx.paths.recordingLog(device: name)
        let offset = ((try? FileManager.default.attributesOfItem(atPath: log))?[.size] as? NSNumber)?.intValue ?? 0
        let process = try detached.start(provisioner.simctl(for: ctx).recordVideoInvocation(udid: device.udid, path: path), log: log)
        let record = RecordingRecord(device: name, udid: device.udid, path: path, log: log, process: process, startedAt: now())
        try await waitUntilRecording(record, logOffset: offset)
        try Recordings.save(record, to: file)
        return RecordingReport(action: .started, device: name, udid: device.udid, path: path, seconds: nil, bytes: nil,
                               outcome: nil, limit: DurationText.format(ctx.config.maxRecording), worktree: ctx.state.name)
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

    /// `--out` against the current directory (it must not exist; its folder is created), or a new file in the media
    /// folder, which is made git-ignored.
    func destination(_ out: String?, device: String, kind: String, ext: String, in ctx: WorktreeContext) throws -> String {
        guard let out else {
            let folder = MediaFolder.resolve(template: ctx.config.mediaDirTemplate, projectRoot: ctx.location.projectRoot,
                                             worktreeRoot: ctx.location.worktreeRoot, worktreeName: ctx.state.name, device: device)
            _ = try? folder.ensureIgnored()
            return folder.newFile(device: device, kind: kind, ext: ext, now: now())
        }
        let expanded = (out as NSString).expandingTildeInPath
        let path = ((expanded.hasPrefix("/") ? expanded : currentDirectory + "/" + expanded) as NSString).standardizingPath
        guard !FileManager.default.fileExists(atPath: path) else {
            throw XcdError(.usage, "\(path) already exists", next: "pick another --out, or delete it first")
        }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return path
    }

    /// simctl prints "Recording started" once it is writing frames. Polls every 100ms, counted in
    /// attempts rather than clock time so tests with an instant `sleep` don't spin.
    func waitUntilRecording(_ record: RecordingRecord, logOffset: Int) async throws {
        let attempts = max(1, Int((DurationText.seconds(startTimeout) * 10).rounded()))
        for _ in 0..<attempts {
            if Self.text(of: record.log, from: logOffset).contains("Recording started") { return }
            guard detached.inspector.isRunning(record.process) else {
                throw XcdError(.simulatorFailed, "simctl stopped before the recording started", next: "run `xcd doctor`",
                               details: ["log: \(record.log)"] + Self.tail(record.log, from: logOffset))
            }
            try await sleep(.milliseconds(100))
        }
        _ = await detached.stop(record.process, marker: nil, signal: SIGINT, timeout: Self.stopTimeout)
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
