import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import XcdevKit

/// `xcd _record-window` makes its clip of stills: synthetic stills go through the real `AVAssetWriter` here.
@Suite struct MacWindowRecorderTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("xcd recorder \(UUID().uuidString)").path
    var clip: String { folder + "/clip.mp4" }

    init() throws { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(atPath: folder) }

    /// A recording on a scripted clock: each still takes 50 ms, a sleep passes at once, and the stop fires with the
    /// `count`th still; the `failing`th still throws instead.
    final class Script {
        var time = 0.0
        var taken = 0
        var started = 0
        let stop = MacWindowRecorder.Flag()

        func stills(count: Int, failing: Int? = nil) -> MacWindowRecorder.Stills {
            MacWindowRecorder.Stills(take: { [self] in
                taken += 1
                if taken == failing { throw XcdError(.runnerFailed, "the window is gone", next: "check the app") }
                time += 0.05
                if taken == count { stop.fire() }
                return try MacWindowRecorderTests.image(shade: taken)
            }, now: { [self] in time }, sleep: { [self] in time += $0 / .seconds(1) }, started: { [self] in started += 1 })
        }
    }

    /// A 65x49 still of one colour; odd sides, which the clip rounds down to even ones for H.264.
    static func image(shade: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 65, height: 49, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: Double(shade % 10) / 10, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 65, height: 49))
        return try #require(context.makeImage())
    }

    struct Clip {
        /// Each frame's time in the clip, in seconds.
        let times: [Double]
        let seconds: Double
        let size: CGSize
    }

    /// What AVFoundation reads back from the file.
    static func read(_ path: String) async throws -> Clip {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        // Decoded frames, which come in presentation order with their own times.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() { times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
        return Clip(times: times, seconds: try await asset.load(.duration).seconds, size: try await track.load(.naturalSize))
    }

    @Test func stillsBecomeAnMP4WithAFramePerStillEachAtItsOwnTime() async throws {
        defer { remove() }
        let script = Script()
        try await MacWindowRecorder.record(script.stills(count: 5), to: clip, until: script.stop)
        // Stills asked for at 0, 0.2, 0.4, 0.6, and 0.8 s; the last one took until 0.85 s, where the clip ends.
        let read = try await Self.read(clip)
        #expect(read.times.map { ($0 * 100).rounded() / 100 } == [0, 0.2, 0.4, 0.6, 0.8], "\(read.times)")
        #expect(abs(read.seconds - 0.85) < 0.01 && read.size == CGSize(width: 64, height: 48))
        #expect(script.started == 1 && script.taken == 5)
    }

    /// A frame offered when the encoder cannot take it (here: the file is no longer being written) is a thrown
    /// failure, never an append AVFoundation may answer with an exception.
    @Test func aFrameTheEncoderCannotTakeIsAFailureNotAnAppend() async throws {
        defer { remove() }
        let writer = try MacClipWriter(path: clip, width: 64, height: 48)
        writer.writer.cancelWriting()
        let error = await #expect(throws: XcdError.self) { try await writer.append(try Self.image(shade: 1), at: 0) }
        #expect(error?.code == .runnerFailed && error?.message.hasPrefix("the video encoder did not take the frame: ") == true)
        #expect(error?.next != nil)
    }

    @Test func aFirstStillThatFailsWritesNothingAndNeverSaysStarted() async throws {
        defer { remove() }
        let script = Script()
        let error = await #expect(throws: XcdError.self) {
            try await MacWindowRecorder.record(script.stills(count: 5, failing: 1), to: clip, until: script.stop)
        }
        #expect(error?.message == "the window is gone" && script.started == 0 && !FileManager.default.fileExists(atPath: clip))
    }

    @Test func aStillThatFailsLaterEndsTheClipWithWhatCameBefore() async throws {
        defer { remove() }
        let script = Script()
        let error = await #expect(throws: XcdError.self) {
            try await MacWindowRecorder.record(script.stills(count: 99, failing: 4), to: clip, until: script.stop)
        }
        #expect(error?.code == .runnerFailed && error?.message == "the recording ended early: the window is gone" && error?.next != nil)
        let read = try await Self.read(clip)
        #expect(read.times.count == 3 && abs(read.seconds - 0.6) < 0.01)
    }
}
