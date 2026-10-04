import Foundation

public enum DeviceTypeProfile {
    /// The main screen's scale (points to pixels) from `<bundlePath>/Contents/Resources/capabilities.plist`
    /// 3 for current iPhones, 2 for iPads.
    public static func scale(bundlePath: String) -> Double? {
        let file = bundlePath + "/Contents/Resources/capabilities.plist"
        guard let data = FileManager.default.contents(atPath: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let capabilities = plist["capabilities"] as? [String: Any],
              let screen = capabilities["ScreenDimensionsCapability"] as? [String: Any] else { return nil }
        return (screen["main-screen-scale"] as? NSNumber)?.doubleValue
    }
}

public enum PNGInfo {
    /// Width and height from the IHDR chunk, which a PNG always starts with.
    public static func size(of path: String) -> (width: Int, height: Int)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 24), header.count == 24,
              header.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
              header[12..<16] == Data("IHDR".utf8) else { return nil }
        func int(_ offset: Int) -> Int { header[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
        return (int(16), int(20))
    }
}
