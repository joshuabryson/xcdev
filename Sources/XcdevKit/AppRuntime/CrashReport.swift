import Foundation

/// The parts of an `.ips` crash report an agent needs: what crashed, how, and where.
public struct CrashReport: Codable, Sendable, Equatable {
    public let path: String
    public let processName: String
    public let pid: Int32
    public let bundleId: String?
    /// e.g. "EXC_BREAKPOINT (SIGTRAP)".
    public let exception: String?
    /// e.g. "Trace/BPT trap: 5".
    public let termination: String?
    /// The faulting thread's first frames: "<image>  <symbol>", plus " (<file>:<line>)" when known.
    public let frames: [String]

    /// `.ips` = one line of JSON header, then a JSON body.
    public static func parse(_ text: String, path: String) throws -> CrashReport {
        struct Frame: Decodable { let symbol: String?; let imageIndex: Int?; let sourceFile: String?; let sourceLine: Int? }
        struct Thread: Decodable { let triggered: Bool?; let frames: [Frame]? }
        struct Image: Decodable { let name: String? }
        struct BundleInfo: Decodable { let CFBundleIdentifier: String? }
        struct Exception: Decodable { let type: String?; let signal: String? }
        struct Termination: Decodable { let indicator: String? }
        struct Body: Decodable {
            let procName: String
            let pid: Int32
            let bundleInfo: BundleInfo?
            let exception: Exception?
            let termination: Termination?
            let faultingThread: Int?
            let threads: [Thread]?
            let usedImages: [Image]?
        }
        guard let newline = text.firstIndex(of: "\n"),
              let body = try? JSONDecoder().decode(Body.self, from: Data(text[text.index(after: newline)...].utf8)) else {
            throw XcdError(.internalError, "\(path) is not a readable .ips crash report")
        }
        let threads = body.threads ?? []
        let thread = body.faultingThread.flatMap { threads.indices.contains($0) ? threads[$0] : nil }
            ?? threads.first { $0.triggered == true }
        let images = body.usedImages ?? []
        let frames = (thread?.frames ?? []).prefix(8).map { frame -> String in
            let image = frame.imageIndex.flatMap { images.indices.contains($0) ? images[$0].name : nil } ?? "?"
            var line = "\(image)  \(frame.symbol ?? "???")"
            if let file = frame.sourceFile, let number = frame.sourceLine {
                line += " (\((file as NSString).lastPathComponent):\(number))"
            }
            return line
        }
        let exception = body.exception?.type.map { type in body.exception?.signal.map { "\(type) (\($0))" } ?? type }
        return CrashReport(path: path, processName: body.procName, pid: body.pid,
                           bundleId: body.bundleInfo?.CFBundleIdentifier, exception: exception,
                           termination: body.termination?.indicator, frames: Array(frames))
    }
}

/// Finds the crash report for one process in DiagnosticReports (simulator apps crash as host processes).
public struct CrashReportLocator: Sendable {
    public let directory: String

    public init(directory: String = NSHomeDirectory() + "/Library/Logs/DiagnosticReports") {
        self.directory = directory
    }

    /// The newest `<process>-*.ips` written since `since` (allowing 2s of clock slack) whose pid matches;
    /// any pid when `pid` is nil (the process died before its pid was seen). Every simulator, and a Mac build of the
    /// same name, writes to this folder: with `simulator`, only a report of a process that ran in that simulator counts.
    public func find(processName: String, pid: Int32? = nil, since: Date, simulator: String? = nil) -> CrashReport? {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        for name in names.sorted(by: >) where name.hasPrefix(processName + "-") && name.hasSuffix(".ips") {
            let path = directory + "/" + name
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  modified >= since.addingTimeInterval(-2),
                  let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let report = try? CrashReport.parse(text, path: path), pid == nil || report.pid == pid,
                  simulator.map({ CrashReport.ranIn(simulator: $0, reportText: text) }) ?? true else { continue }
            return report
        }
        return nil
    }
}

extension CrashReport {
    /// Whether the `.ips` text is a crash of a process that ran in simulator `udid`: its `procPath` is inside that
    /// device's folder. The UDID identifies the device because the home folder is redacted in reports. False when
    /// the text has no readable `procPath`.
    static func ranIn(simulator udid: String, reportText text: String) -> Bool {
        struct Body: Decodable { let procPath: String? }
        guard let newline = text.firstIndex(of: "\n"),
              let body = try? JSONDecoder().decode(Body.self, from: Data(text[text.index(after: newline)...].utf8)),
              let path = body.procPath else { return false }
        return path.contains("/CoreSimulator/Devices/\(udid)/")
    }
}
