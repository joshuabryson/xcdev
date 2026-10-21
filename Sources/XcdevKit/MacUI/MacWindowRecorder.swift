import AVFoundation
import Foundation
import ScreenCaptureKit
import Synchronization

/// Records one window to an MP4 until SIGINT. Runs inside `xcd _record-window`, a detached process.
public enum MacWindowRecorder {
    /// The subcommand's name: the argument that identifies the recorder, so a reused pid is never taken for it.
    public static let marker = "_record-window"

    /// A one-shot signal: the delegate's "finished" may arrive before anyone waits for it, so the first of the two
    /// sides to run leaves its mark and the second one completes the wait. Called from the stream's queue and the task.
    final class Gate: Sendable {
        private let state = Mutex<(fired: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

        func fire() {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.fired = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state -> Bool in
                    if state.fired { return true }
                    state.waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
    }

    /// The stream's and the recording's delegate. `stopped` fires on SIGINT or SIGTERM, or when the stream ends on its
    /// own (the window closed, the app quit), so a dead stream does not leave the recorder waiting for a signal;
    /// `finished` fires once the file is final, or the recording failed, which `failure` then says.
    final class Finish: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, Sendable {
        let stopped = Gate()
        let finished = Gate()
        let failure = Mutex<String?>(nil)

        func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { finished.fire() }

        func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) { fail(error) }

        func stream(_ stream: SCStream, didStopWithError error: any Error) { fail(error) }

        /// The first failure is the one reported.
        func fail(_ error: any Error) {
            failure.withLock { $0 = $0 ?? error.localizedDescription }
            stopped.fire()
            finished.fire()
        }
    }

    /// Starts the stream, writes "Recording started" to its log (stderr), waits for SIGINT, stops, and returns once the
    /// file is final. The signals are taken before the stream starts, so a stop sent right after the line is not lost.
    /// A recording that failed throws, so the recorder exits with an error its log names.
    public static func record(windowID: UInt32, to path: String, scale: Double) async throws {
        let window = try await window(windowID)
        let finish = Finish()
        let configuration = ScreenCaptureKitCapture.configuration(width: window.frame.width, height: window.frame.height, scale: scale)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: finish)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: output(path), delegate: finish))
        let sources = listen([SIGINT, SIGTERM], firing: finish.stopped)
        defer { sources.forEach { $0.cancel() } }
        try await stream.startCapture()
        StandardError.write("Recording started\n")
        await finish.stopped.wait()
        if finish.failure.withLock({ $0 }) == nil { try await stream.stopCapture() }
        await finish.finished.wait()
        if let failure = finish.failure.withLock({ $0 }) {
            throw XcdError(.runnerFailed, "the recording of window \(windowID) failed: \(failure)",
                           next: "a hidden window gives ScreenCaptureKit no frames to record (a screenshot still works): "
                               + "relaunch the app with `xcd launch --show`, then record again")
        }
    }

    static func window(_ id: UInt32) async throws -> SCWindow {
        guard let window = try await ScreenCaptureKitCapture.windows().first(where: { $0.windowID == id }) else {
            throw XcdError(.elementNotFound, "no window \(id) to record", next: "run `xcd ui tree`, then start the recording again")
        }
        return window
    }

    static func output(_ path: String) -> SCRecordingOutputConfiguration {
        let output = SCRecordingOutputConfiguration()
        output.outputURL = URL(fileURLWithPath: path)
        output.outputFileType = .mp4
        output.videoCodecType = .h264
        return output
    }

    /// Ignores the signals, so they no longer end the process, and fires `gate` on any of them, on a queue of its own:
    /// the main queue is not drained while the task waits. The sources must be kept until the recording ends.
    static func listen(_ signals: [Int32], firing gate: Gate) -> [any DispatchSourceSignal] {
        let queue = DispatchQueue(label: "dev.xcdev.record-window.signals")
        return signals.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { gate.fire() }
            source.resume()
            return source
        }
    }
}
