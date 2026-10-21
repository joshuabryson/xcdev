import AppKit
import Foundation
import ScreenCaptureKit

public struct CapturedWindow: Sendable, Equatable {
    public let id: UInt32
    public let title: String
    /// Screen points, top-left origin.
    public let frame: ScreenRect
    public init(id: UInt32, title: String, frame: ScreenRect) {
        self.id = id
        self.title = title
        self.frame = frame
    }
}

public struct ScreenshotInfo: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let scale: Double
    public init(width: Int, height: Int, scale: Double) {
        self.width = width
        self.height = height
        self.scale = scale
    }
}

/// A still of one window, hidden or covered. Needs Screen Recording for the host app.
public protocol WindowCapturing: Sendable {
    /// The app's window titled as its Accessibility main window, the one with the content (`MacSnapshot.mainTitle`);
    /// nil when it lists none by that title.
    func mainWindow(pid: Int32, title: String) async throws -> CapturedWindow?
    func screenshot(_ window: CapturedWindow, to path: String) async throws -> ScreenshotInfo
}

/// A window ScreenCaptureKit lists for the app, with its layer: what the pick chooses from.
struct WindowCandidate: Equatable {
    let window: CapturedWindow
    let layer: Int

    /// The window with the main window's title; of several, the largest at layer 0; of equals, the first. When an app
    /// hides, AppKit adds an untitled 500x500 window to its list, so "the first" alone is never the rule.
    static func pick(_ candidates: [WindowCandidate], title: String) -> CapturedWindow? {
        let titled = candidates.filter { $0.window.title == title }
        let normal = titled.filter { $0.layer == 0 }
        // `max(by:)` keeps the first of equal maxima.
        return (normal.isEmpty ? titled : normal).max { $0.window.frame.w * $0.window.frame.h < $1.window.frame.w * $1.window.frame.h }?.window
    }
}

public struct ScreenCaptureKitCapture: WindowCapturing {
    public init() { /* nothing to hold: each call asks ScreenCaptureKit afresh */ }

    /// Every window, on screen or not: a hidden app's window is off screen and still captures in full.
    static func windows() async throws -> [SCWindow] {
        // ScreenCaptureKit aborts a process that has not connected to the window server yet ("Assertion failed:
        // (did_initialize), function CGS_REQUIRE_INIT", measured in `xcd _record-window`); asking for a display connects it.
        _ = CGMainDisplayID()
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false).windows
        } catch {
            throw XcdError(.runnerFailed, "ScreenCaptureKit could not list the windows: \(error.localizedDescription)",
                           next: "run `xcd ui tree` to check the app, then retry; `xcd doctor` if it keeps failing")
        }
    }

    public func mainWindow(pid: Int32, title: String) async throws -> CapturedWindow? {
        let candidates = try await Self.windows().filter { $0.owningApplication?.processID == pid && $0.frame.width > 1 }.map { window in
            WindowCandidate(window: CapturedWindow(id: window.windowID, title: window.title ?? "",
                                                   frame: ScreenRect(x: window.frame.minX, y: window.frame.minY, w: window.frame.width, h: window.frame.height)),
                            layer: window.windowLayer)
        }
        return WindowCandidate.pick(candidates, title: title)
    }

    public func screenshot(_ window: CapturedWindow, to path: String) async throws -> ScreenshotInfo {
        guard let target = try await Self.windows().first(where: { $0.windowID == window.id }) else {
            throw XcdError(.elementNotFound, "the window is gone", next: "run `xcd ui tree`, then retry")
        }
        let scale = SystemAccessibility().screenScale(containing: window.frame)
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target),
                                                               configuration: Self.configuration(width: window.frame.w, height: window.frame.h, scale: scale))
        } catch {
            throw XcdError(.runnerFailed, "ScreenCaptureKit could not capture the window: \(error.localizedDescription)",
                           next: "run `xcd ui tree` to check the app, then retry; `xcd doctor` if it keeps failing")
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw XcdError(.internalError, "could not encode the screenshot as PNG",
                           next: "run `xcd ui screenshot` again; if it keeps failing, report it")
        }
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        return ScreenshotInfo(width: image.width, height: image.height, scale: scale)
    }

    /// A window of `width` by `height` points at `scale` pixels per point, without the pointer: for a still or a recording.
    static func configuration(width: Double, height: Double, scale: Double) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(width * scale)
        configuration.height = Int(height * scale)
        configuration.showsCursor = false
        return configuration
    }
}
