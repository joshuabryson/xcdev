public struct BuildReport: Reportable {
    public let succeeded: Bool
    public let scheme: String
    public let target: String
    public let targetSummary: String
    public let seconds: Double
    public let errors: [Diagnostic]
    public let warningCount: Int
    /// Only with `--warnings`.
    public let warnings: [Diagnostic]?
    public let product: AppProduct?
    public let log: String
    public let resultBundle: String?
    /// The log's last lines, when xcodebuild failed without reporting an error.
    public let logTail: [String]?
    public let worktree: String
    /// What about the worktree's setup the reader should know, e.g. that it slows every build (`SetupNotes`).
    public var notes: [String] = []

    public init(succeeded: Bool, scheme: String, target: String, targetSummary: String, seconds: Double,
                errors: [Diagnostic], warningCount: Int, warnings: [Diagnostic]?, product: AppProduct?, log: String,
                resultBundle: String?, logTail: [String]?, worktree: String) {
        self.succeeded = succeeded
        self.scheme = scheme
        self.target = target
        self.targetSummary = targetSummary
        self.seconds = seconds
        self.errors = errors
        self.warningCount = warningCount
        self.warnings = warnings
        self.product = product
        self.log = log
        self.resultBundle = resultBundle
        self.logTail = logTail
        self.worktree = worktree
    }

    public var headline: String {
        "build \(succeeded ? "succeeded" : "failed")  scheme=\(scheme) device=\(targetSummary)  \(DurationText.format(.seconds(seconds)))"
    }

    public var text: String {
        var lines = [headline]
        lines += errors.map(\.text)
        lines += (warnings ?? []).map(\.text)
        if !succeeded || warningCount > 0 {
            var counts = succeeded ? "" : "\(errors.count) error\(errors.count == 1 ? "" : "s"), "
            counts += "\(warningCount) warning\(warningCount == 1 ? "" : "s")"
            if warnings == nil && warningCount > 0 { counts += " (xcd build --warnings)" }
            lines.append(counts)
        }
        if let product { lines.append("app: \(product.path)  bundle=\(product.bundleId)") }
        lines += (logTail ?? []).map { "  " + $0 }
        lines += notes.map { "note: " + $0 }
        lines.append("log: \(log)")
        return lines.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktree }

    public var failure: XcdError? {
        guard !succeeded else { return nil }
        return XcdError(.buildFailed, "build failed with \(errors.count) error\(errors.count == 1 ? "" : "s")",
                        next: "fix the errors and re-run `xcd build`")
    }
}

public struct CleanReport: Reportable {
    public let deep: Bool
    public let scheme: String?
    /// The DerivedData folder `--deep` deleted, or nil if there was none.
    public let removed: String?
    public let derivedData: String
    public let log: String?
    public let worktree: String

    public var text: String {
        if deep {
            return removed.map { "removed \($0)" } ?? "nothing to remove; \(derivedData) does not exist"
        }
        return "cleaned scheme=\(scheme ?? "-")\nlog: \(log ?? "-")"
    }

    public var envelopeWorktree: String? { worktree }
}
