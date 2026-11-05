import Foundation
import XcdevKit

/// Stand-ins for the two formatters that really read what they are given, so tests see what xcd handed over and
/// what it did with the answer. Their one rule: a line loses the blanks at its end, and each tab it starts with
/// becomes four spaces. A run with no range also ends the text with a newline. What they do at the edges is what
/// the real tools were seen to do:
/// - swift-format reads the file named last, takes each range as UTF-8 offsets and formats every line a range
///   touches, prints nothing for a file the worktree's `.swift-format-ignore` names, and for a file it cannot read as
///   Swift exits 1 with nothing on stdout and the file's full path in its error.
/// - SwiftFormat reads standard input, takes one range per run, and for such a file exits 70 with its input printed
///   back and an error that names no file.
/// A file "cannot be read as Swift" here when a line starts with `<<<<<<<`, as in an unresolved conflict, and each
/// stand-in then says what its tool says of such a file.
public final class FakeFormatters: Sendable {
    /// One run of a formatter.
    public struct Run: Sendable, Equatable {
        /// `swift-format` or `swiftformat`.
        public let tool: String
        /// The file, as the formatter was told its path.
        public let file: String
        /// Each range as its first and last line. Empty for a run on the whole file.
        public let ranges: [[Int]]
        /// The text the formatter read.
        public let text: String
        /// Where its standard input came from. Nil for swift-format, which reads the file itself.
        public let inputFile: String?
    }

    private let seen = Shared<[Run]>([])
    private let running = Counter()
    private let most = Shared<Int>(0)
    /// How many runs wait for one another before any answers, so that a test can see runs overlap. 1: none waits.
    private let together: Int
    /// Set when a run waited in vain, so that the runs after it do not wait as long again.
    private let gaveUp = Shared<Bool>(false)
    private let stderr: String

    /// `stderr` is what each run says while it succeeds.
    public init(together: Int = 1, stderr: String = "") {
        self.together = together
        self.stderr = stderr
    }

    /// The runs so far, in the order they started.
    public var runs: [Run] { seen.value }
    /// The most runs that were under way at one moment.
    public var mostAtOnce: Int { most.value }

    /// Answers every `swift-format` and `swiftformat` invocation on `runner`.
    public func install(on runner: FakeProcessRunner) {
        runner.stub(["swift-format"], suspending: { [self] invocation in
            let file = invocation.arguments.last ?? ""
            let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            let ranges = Self.lines(touchedBy: Self.values(after: "--offsets", in: invocation.arguments, separator: ":"), in: text)
            return await answer(Run(tool: "swift-format", file: file, ranges: ranges, text: text, inputFile: nil), in: invocation.workingDirectory ?? "")
        })
        runner.stub(["swiftformat"], suspending: { [self] invocation in
            let file = Self.values(after: "--stdin-path", in: invocation.arguments).first ?? ""
            let text = (try? String(contentsOfFile: invocation.inputFile ?? "", encoding: .utf8)) ?? ""
            let ranges = Self.values(after: "--line-range", in: invocation.arguments, separator: ",")
            return await answer(Run(tool: "swiftformat", file: file, ranges: ranges, text: text, inputFile: invocation.inputFile), in: "")
        })
    }

    /// The arguments that follow each `flag`, each split at `separator` into whole numbers.
    static func values(after flag: String, in arguments: [String], separator: Character) -> [[Int]] {
        values(after: flag, in: arguments).map { $0.split(separator: separator).compactMap { Int($0) } }
    }

    /// The first and last line of `text` that each pair of UTF-8 offsets touches, both offsets counted in.
    static func lines(touchedBy offsets: [[Int]], in text: String) -> [[Int]] {
        var starts = [0]
        for (offset, byte) in text.utf8.enumerated() where byte == UInt8(ascii: "\n") { starts.append(offset + 1) }
        func line(_ offset: Int) -> Int { (starts.lastIndex { $0 <= offset } ?? 0) + 1 }
        return offsets.filter { $0.count == 2 }.map { [line($0[0]), line($0[1])] }
    }

    static func values(after flag: String, in arguments: [String]) -> [String] {
        arguments.indices.dropLast().filter { arguments[$0] == flag }.map { arguments[$0 + 1] }
    }

    func answer(_ run: Run, in worktree: String) async -> ProcessOutput {
        seen.change { $0.append(run) }
        let now = running.increment()
        most.change { $0 = max($0, now) }
        defer { running.decrement() }
        await waitForCompany()
        let lines = run.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let bad = lines.firstIndex(where: { $0.hasPrefix("<<<<<<<") }) { return Self.unreadable(run, line: bad + 1) }
        if run.tool == "swift-format", Self.ignores(run.file, in: worktree) { return ProcessOutput(exitCode: 0, stdout: "", stderr: stderr) }
        let whole = run.ranges.isEmpty
        var tidied = lines.enumerated().map { index, line in
            whole || run.ranges.contains { $0[0] <= index + 1 && index + 1 <= $0[1] } ? Self.tidy(line) : line
        }
        if whole, tidied.last != "" { tidied.append("") }
        return ProcessOutput(exitCode: 0, stdout: tidied.joined(separator: "\n"), stderr: stderr)
    }

    /// With `together` above 1: waits until that many runs are under way at once, for up to five seconds, and then
    /// stays a moment longer, so that a run started beyond a limit would be counted too. It suspends while it waits,
    /// so the runs overlap however few threads the tests have.
    func waitForCompany() async {
        guard together > 1 else { return }
        let deadline = ContinuousClock.now + .seconds(5)
        while most.value < together, ContinuousClock.now < deadline, !gaveUp.value {
            try? await Task.sleep(for: .milliseconds(1))
        }
        if most.value < together { gaveUp.set(true) }
        try? await Task.sleep(for: .milliseconds(20))
    }

    /// A line without the blanks at its end, and with four spaces for each tab at its start.
    public static func tidy(_ line: String) -> String {
        let kept = line.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression)
        let tabs = kept.prefix { $0 == "\t" }.count
        return String(repeating: "    ", count: tabs) + kept.dropFirst(tabs)
    }

    static func unreadable(_ run: Run, line: Int) -> ProcessOutput {
        run.tool == "swift-format"
            ? ProcessOutput(exitCode: 1, stdout: "", stderr: "\(run.file):\(line):1: error: source control conflict marker in source file\n")
            : ProcessOutput(exitCode: 70, stdout: run.text, stderr: "error: Found conflict marker <<<<<<< at \(line):1.\n")
    }

    /// Whether the worktree's `.swift-format-ignore` names `file`: a line that is the file's path from the root, or `*`.
    static func ignores(_ file: String, in worktree: String) -> Bool {
        guard let ignored = try? String(contentsOfFile: worktree + "/.swift-format-ignore", encoding: .utf8) else { return false }
        let relative = file.hasPrefix(worktree + "/") ? String(file.dropFirst(worktree.count + 1)) : file
        return ignored.split(separator: "\n").contains { $0 == "*" || $0 == relative }
    }
}
