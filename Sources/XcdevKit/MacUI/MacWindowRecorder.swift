import CoreGraphics
import Foundation
import ScreenCaptureKit
import Synchronization

/// Records one window to an MP4 until SIGINT. Runs inside `xcd _record-window`, a detached process.
///
/// The clip is made of stills, up to five a second. ScreenCaptureKit suspends an `SCStream` of a window that is not on
/// screen and delivers it no frames, whatever the filter or configuration (measured 2026-10-20 on a hidden app), while
/// a still of the same window comes in full; stills are the one route that works visible, covered, hidden, and minimized.
public enum MacWindowRecorder {
    /// The subcommand's name: the argument that identifies the recorder, so a reused pid is never taken for it.
    public static let marker = "_record-window"
    /// One still every 200 ms, or as fast as they come when a still takes longer.
    static let interval: Duration = .milliseconds(200)

    /// A one-way switch, set from the signal queue and read by the recording loop.
    final class Flag: Sendable {
        private let state = Mutex(false)

        func fire() { state.withLock { $0 = true } }
        var fired: Bool { state.withLock { $0 } }
    }

    /// Where the stills come from and how time passes: ScreenCaptureKit and the clock, or a test's script.
    struct Stills {
        /// One still of the window.
        var take: () async throws -> CGImage
        /// Seconds on a steady clock. A still's time in the clip is when it was asked for.
        var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
        var sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        /// Called once the first still is in the file: `record start` waits for this line in the recorder's log.
        var started: () -> Void = { StandardError.write("Recording started\n") }
    }

    /// Records until SIGINT or SIGTERM. The signals are taken before the first still, so a stop sent right after
    /// "Recording started" is not lost, and the file is finished before the process ends.
    public static func record(windowID: UInt32, to path: String, scale: Double) async throws {
        let window = try await window(windowID)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = ScreenCaptureKitCapture.configuration(width: window.frame.width, height: window.frame.height, scale: scale)
        let stop = Flag()
        let sources = listen([SIGINT, SIGTERM], firing: stop)
        defer { sources.forEach { $0.cancel() } }
        let take: () async throws -> CGImage = {
            do {
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            } catch {
                throw XcdError(.runnerFailed, "could not take a still of window \(windowID): \(error.localizedDescription)",
                               next: "check the app with `xcd ui tree`, then start the recording again")
            }
        }
        try await record(Stills(take: take), to: path, until: stop)
    }

    /// Takes the first still, starts the file with it, says so, then adds a still every `interval` until `stop`, and
    /// finishes the file. A first still that fails is thrown before anything is written, so `record start` fails at
    /// once; a later one that fails (the window closed) ends the clip there, and the file is finished before the throw.
    static func record(_ stills: Stills, to path: String, until stop: Flag) async throws {
        let start = stills.now()
        let first = try await stills.take()
        let clip = try MacClipWriter(path: path, width: first.width, height: first.height)
        try await clip.append(first, at: 0)
        stills.started()
        var taken = start
        var failure: (any Error)?
        while !stop.fired {
            let wait = interval - .seconds(stills.now() - taken)
            if wait > .zero { await stills.sleep(wait) }
            if stop.fired { break }
            taken = stills.now()
            do { try await clip.append(try await stills.take(), at: taken - start) } catch {
                failure = error
                break
            }
        }
        try await clip.finish(at: stills.now() - start)
        if let failure { throw ended(by: failure) }
    }

    /// The error of a recording that ended before it was stopped; the file holds what came before.
    static func ended(by failure: any Error) -> XcdError {
        XcdError(.runnerFailed, "the recording ended early: \((failure as? XcdError)?.message ?? failure.localizedDescription)",
                 next: "the video keeps what was recorded until then; check the app with `xcd ui tree`")
    }

    static func window(_ id: UInt32) async throws -> SCWindow {
        guard let window = try await ScreenCaptureKitCapture.windows().first(where: { $0.windowID == id }) else {
            throw XcdError(.elementNotFound, "no window \(id) to record", next: "run `xcd ui tree`, then start the recording again")
        }
        return window
    }

    /// Ignores the signals, so they no longer end the process, and fires `flag` on any of them, on a queue of its own.
    /// The sources must be kept until the recording ends.
    static func listen(_ signals: [Int32], firing flag: Flag) -> [any DispatchSourceSignal] {
        let queue = DispatchQueue(label: "dev.xcdev.record-window.signals")
        return signals.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { flag.fire() }
            source.resume()
            return source
        }
    }
}
