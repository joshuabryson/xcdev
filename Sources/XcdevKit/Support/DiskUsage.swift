import Foundation

/// Disk usage from `du -sk`. du counts APFS clones (cloned simulators, copy-on-write SourcePackages) in
/// full, so totals are upper bounds.
public struct DiskUsage: Sendable {
    public let runner: any ProcessRunning

    public init(runner: any ProcessRunning) { self.runner = runner }

    /// Bytes used under each existing path. One `du` call; paths that don't exist are left out
    /// (du reports them on stderr, exits 1, and still measures the rest). Empty when du can't run.
    public func bytes(of paths: [String]) async -> [String: Int64] {
        guard !paths.isEmpty,
              let out = try? await runner.run(Invocation("/usr/bin/du", ["-sk"] + paths, timeout: .seconds(120))) else { return [:] }
        return Self.parse(out.stdoutString)
    }

    /// `du -sk` lines: "<kilobytes>\t<path>".
    static func parse(_ text: String) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for line in text.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let kilobytes = Int64(line[..<tab]) else { continue }
            sizes[String(line[line.index(after: tab)...])] = kilobytes * 1024
        }
        return sizes
    }
}

public enum ByteText {
    /// "0B", "512B", "296KB", "12.3MB", "1.2GB" (1 KB = 1024 bytes).
    public static func format(_ bytes: Int64) -> String {
        let units = ["KB", "MB", "GB", "TB"]
        guard bytes >= 1024 else { return "\(bytes)B" }
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(Int(value.rounded()))KB" : String(format: "%.1f%@", value, units[unit])
    }
}
