import Darwin
import Foundation

/// One run of a process. Its pid can be reused once it exits; pid plus kernel start time can't. Exec keeps the start
/// time but changes the arguments (`sh -c "exec sleep 1"` reads back as `sleep 1`), so they are read back, not assumed.
public struct ProcessIdentity: Codable, Sendable, Equatable {
    public let pid: Int32
    /// Seconds since 1970 when the kernel started the process.
    public let startTime: Double
    public let arguments: [String]

    public init(pid: Int32, startTime: Double, arguments: [String]) {
        self.pid = pid
        self.startTime = startTime
        self.arguments = arguments
    }
}

public protocol ProcessInspecting: Sendable {
    /// The process `pid` while it runs (not once it has exited), or nil. Only this user's processes can be read.
    func identity(of pid: Int32) -> ProcessIdentity?
    /// Sends `signal` to the process group `pid` leads. Returns whether it was delivered.
    @discardableResult
    func signalGroup(_ pid: Int32, _ signal: Int32) -> Bool
}

extension ProcessInspecting {
    /// Whether `identity` still runs: same pid and start time, and with `marker`, an argument containing it.
    public func isRunning(_ identity: ProcessIdentity, marker: String? = nil) -> Bool {
        guard let current = self.identity(of: identity.pid), current.startTime == identity.startTime else { return false }
        return marker.map { marker in current.arguments.contains { $0.contains(marker) } } ?? true
    }
}

public struct SystemProcessInspector: ProcessInspecting {
    public init() {}

    /// `pbi_status` of a process that has exited but not been reaped (SZOMB in <sys/proc.h>).
    private static let zombie: UInt32 = 5

    public func identity(of pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != Self.zombie else { return nil }
        let start = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
        return ProcessIdentity(pid: pid, startTime: start, arguments: Self.arguments(of: pid) ?? [])
    }

    public func signalGroup(_ pid: Int32, _ signal: Int32) -> Bool { pid > 0 && kill(-pid, signal) == 0 }

    /// argv from `KERN_PROCARGS2`: argc, the executable path, padding, then the arguments, NUL-separated.
    static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
