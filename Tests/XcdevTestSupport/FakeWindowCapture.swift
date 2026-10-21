import Foundation
import Synchronization
import XcdevKit

/// ScreenCaptureKit for one app with at most one window. The window is found when its title is the one asked for, as
/// the real capture matches the Accessibility main window's title; a screenshot writes a PNG signature and returns `info`.
public final class FakeWindowCapture: WindowCapturing, Sendable {
    let window: CapturedWindow?
    let info: ScreenshotInfo
    let paths = Mutex<[String]>([])

    public init(window: CapturedWindow?, info: ScreenshotInfo = ScreenshotInfo(width: 1800, height: 1104, scale: 2)) {
        self.window = window
        self.info = info
    }

    /// Where each screenshot was written, in order.
    public var captured: [String] { paths.withLock { $0 } }

    public func mainWindow(pid: Int32, title: String) async throws -> CapturedWindow? {
        window?.title == title ? window : nil
    }

    public func screenshot(_ window: CapturedWindow, to path: String) async throws -> ScreenshotInfo {
        paths.withLock { $0.append(path) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: path))
        return info
    }
}
