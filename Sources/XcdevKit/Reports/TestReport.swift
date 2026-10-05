import Foundation

public struct TestReport: Reportable {
    public enum Outcome: String, Codable, Sendable {
        case passed, failed
        case buildFailed = "build_failed"
        case noTests = "no_tests"
    }

    public let outcome: Outcome
    public let scheme: String
    public let target: String
    public let targetSummary: String
    public let seconds: Double
    public let counts: TestCounts
    public let failures: [TestFailure]
    /// The build's errors, or, when xcodebuild failed without structured errors or failing tests,
    /// its own `xcodebuild: error:` lines (or one error pointing at `logTail`).
    public let buildErrors: [Diagnostic]
    /// Whether --only or --skip was given.
    public let filtered: Bool
    /// The first --only value, used to show the parenthesized form in hints.
    public let exampleFilter: String?
    public let resultBundle: String?
    public let log: String
    /// The log's last lines, when xcodebuild failed without reporting an error.
    public let logTail: [String]?
    public let worktree: String
    /// What xcd did around the run that the reader should know, e.g. that it stopped the UI runner.
    public var notes: [String] = []

    public init(outcome: Outcome, scheme: String, target: String, targetSummary: String, seconds: Double,
                counts: TestCounts, failures: [TestFailure], buildErrors: [Diagnostic], filtered: Bool,
                exampleFilter: String?, resultBundle: String?, log: String, logTail: [String]?, worktree: String) {
        self.outcome = outcome
        self.scheme = scheme
        self.target = target
        self.targetSummary = targetSummary
        self.seconds = seconds
        self.counts = counts
        self.failures = failures
        self.buildErrors = buildErrors
        self.filtered = filtered
        self.exampleFilter = exampleFilter
        self.resultBundle = resultBundle
        self.log = log
        self.logTail = logTail
        self.worktree = worktree
    }

    public var text: String {
        let title: String
        switch outcome {
        case .passed: title = "tests passed"
        case .failed: title = "tests failed"
        case .buildFailed: title = "tests did not run: build failed"
        case .noTests: title = "no tests ran"
        }
        var lines = ["\(title)  scheme=\(scheme) device=\(targetSummary)  \(DurationText.format(.seconds(seconds)))"]
        if outcome == .passed || outcome == .failed {
            var summary = "passed=\(counts.passed) failed=\(counts.failed) skipped=\(counts.skipped)"
            if counts.expectedFailures > 0 { summary += " expected-failures=\(counts.expectedFailures)" }
            lines.append(summary)
        }
        lines += failures.map(\.diagnostic.text)
        lines += buildErrors.map(\.text)
        lines += (logTail ?? []).map { "  " + $0 }
        lines += notes.map { "note: " + $0 }
        if let resultBundle { lines.append("result: \(resultBundle)") }
        lines.append("log: \(log)")
        return lines.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktree }

    public var failure: XcdError? {
        switch outcome {
        case .passed:
            return nil
        case .failed:
            var seen = Set<String>()
            let ids = failures.map(\.test).filter { seen.insert($0).inserted }
            let failed = max(counts.failed, ids.count)
            guard failed > 0 else {
                // xcodebuild failed after tests ran, none of which failed; `buildErrors` says why.
                return XcdError(.testFailed, "the test run failed without a failing test",
                                next: "read the errors above and the log, then re-run `xcd test`")
            }
            let rerun = ids.isEmpty
                ? "fix the failing tests and re-run `xcd test`"
                : "fix the failing tests, then re-run them with `xcd test " + ids.map { "--only " + Shell.quote($0) }.joined(separator: " ") + "`"
            return XcdError(.testFailed, "\(failed) test\(failed == 1 ? "" : "s") failed", next: rerun)
        case .buildFailed:
            return XcdError(.buildFailed,
                            "the tests did not build (\(buildErrors.count) error\(buildErrors.count == 1 ? "" : "s"))",
                            next: "fix the errors and re-run `xcd test`")
        case .noTests:
            let example = (exampleFilter ?? "Target/testName").replacingOccurrences(of: "()", with: "") + "()"
            return XcdError(.testFailed, "no tests ran",
                            next: filtered
                                ? "check the --only/--skip identifiers; Swift Testing names need parentheses, e.g. `\(example)`"
                                : "check that the \(scheme) scheme's test action includes test targets")
        }
    }
}
