import Foundation
import XcdevKit

/// A stand-in for SwiftLint that really reads the folder it is run in, so tests see what xcd put there.
/// Its rules: a line with `print(` is a `no_print` warning, a line with `abort(` is a `no_abort` error, and a
/// file with more than `maxLines` lines gets a `file_length` warning on line 1 whose message carries the count.
/// It lints every `.swift` file under the folder, and reports paths the way SwiftLint does: absolute.
public final class FakeSwiftLint: Sendable {
    /// One run: the Swift files and the other files the folder held, as relative paths, and each file's text.
    public struct Run: Sendable {
        public let folder: String
        public let swiftFiles: [String]
        public let otherFiles: [String]
        public let texts: [String: String]
        /// Each file's bytes, also for a file that is not text.
        public let bytes: [String: Data]
    }

    public let maxLines: Int
    private let seen = Shared<[Run]>([])
    private let stderr: String

    public init(maxLines: Int = 10, stderr: String = "") {
        self.maxLines = maxLines
        self.stderr = stderr
    }

    /// The runs so far, in order.
    public var runs: [Run] { seen.value }

    /// Answers every `swiftlint` invocation on `runner`.
    public func install(on runner: FakeProcessRunner) {
        runner.stub(["swiftlint"]) { [self] invocation in
            let folder = invocation.workingDirectory ?? ""
            let run = Self.read(folder)
            seen.change { $0.append(run) }
            let findings = run.swiftFiles.flatMap { self.findings(in: run.texts[$0] ?? "", at: folder + "/" + $0) }
            let hasError = findings.contains { $0.contains(#""severity" : "Error""#) }
            return ProcessOutput(exitCode: hasError ? 2 : 0, stdout: "[\n" + findings.joined(separator: ",\n") + "\n]\n", stderr: stderr)
        }
    }

    static func read(_ folder: String) -> Run {
        let fm = FileManager.default
        let all = ((try? fm.subpathsOfDirectory(atPath: folder)) ?? []).sorted().filter { path in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: folder + "/" + path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        var texts: [String: String] = [:]
        var bytes: [String: Data] = [:]
        for path in all {
            bytes[path] = fm.contents(atPath: folder + "/" + path)
            texts[path] = bytes[path].flatMap { String(data: $0, encoding: .utf8) }
        }
        return Run(folder: folder, swiftFiles: all.filter { $0.hasSuffix(".swift") }, otherFiles: all.filter { !$0.hasSuffix(".swift") },
                   texts: texts, bytes: bytes)
    }

    func findings(in text: String, at file: String) -> [String] {
        // Lines as SwiftLint numbers them: a CR and an LF each end one, so a line that ends in CRLF is followed by an empty one.
        let lines = text.unicodeScalars.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" }.map { String($0) }
        var found: [String] = []
        if lines.count - 1 > maxLines {
            found.append(Self.json(file, 1, nil, "Warning", "file_length", "File should contain \(maxLines) lines or less: currently contains \(lines.count - 1)"))
        }
        for (index, line) in lines.enumerated() {
            for (needle, severity, rule) in [("print(", "Warning", "no_print"), ("abort(", "Error", "no_abort")] {
                guard let range = line.range(of: needle) else { continue }
                let column = line.distance(from: line.startIndex, to: range.lowerBound) + 1
                found.append(Self.json(file, index + 1, column, severity, rule, "\(rule) is not allowed"))
            }
        }
        return found
    }

    static func json(_ file: String, _ line: Int, _ column: Int?, _ severity: String, _ rule: String, _ reason: String) -> String {
        """
          {
            "character" : \(column.map(String.init) ?? "null"),
            "file" : "\(file)",
            "line" : \(line),
            "reason" : "\(reason)",
            "rule_id" : "\(rule)",
            "severity" : "\(severity)",
            "type" : "\(rule)"
          }
        """
    }
}
