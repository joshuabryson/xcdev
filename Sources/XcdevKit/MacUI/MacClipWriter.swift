import AVFoundation
import CoreGraphics
import Foundation

/// An H.264 MP4 written one still at a time, each at its own time in the clip, for `xcd _record-window`. Lives inside
/// the one recording task that made it.
final class MacClipWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    /// The clip's size in pixels: the first still's, rounded down to even sides, as H.264 wants. A later still of
    /// another size is scaled to it.
    let width: Int
    let height: Int

    init(path: String, width: Int, height: Int) throws {
        self.width = max(2, width & ~1)
        self.height = max(2, height & ~1)
        writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                      AVVideoWidthKey: self.width, AVVideoHeightKey: self.height])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: self.width, kCVPixelBufferHeightKey as String: self.height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw failure("could not start the video file") }
        writer.startSession(atSourceTime: .zero)
    }

    /// Adds `image` at `seconds` into the clip, which must be later than the frame before. Waits up to a second for the
    /// encoder to take more. Appending while it is not ready, or once the file has stopped being written, is a
    /// programming error to AVFoundation (it may raise rather than return false), so that is a thrown failure instead.
    func append(_ image: CGImage, at seconds: Double) async throws {
        var tries = 0
        while writer.status == .writing, !input.isReadyForMoreMediaData, tries < 200 {
            try? await Task.sleep(for: .milliseconds(5))
            tries += 1
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { throw failure("the video encoder did not take the frame") }
        let buffer = try pixels(of: image)
        guard adaptor.append(buffer, withPresentationTime: Self.time(seconds)) else { throw failure("could not add a frame to the video") }
    }

    /// Ends the clip at `seconds`, after its last frame, and writes the file out.
    func finish(at seconds: Double) async throws {
        input.markAsFinished()
        writer.endSession(atSourceTime: Self.time(seconds))
        await writer.finishWriting()
        guard writer.status == .completed else { throw failure("could not finish the video file") }
    }

    /// The image drawn into a buffer from the adaptor's pool, scaled to the clip's size.
    func pixels(of image: CGImage) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess,
              let buffer = made else { throw failure("could not get a frame buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let context else { throw failure("could not draw a frame") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    func failure(_ what: String) -> XcdError {
        XcdError(.runnerFailed, "\(what): \(writer.error?.localizedDescription ?? "AVAssetWriter gave no reason")",
                 next: "check that the folder of --out can be written, then start the recording again")
    }
}
