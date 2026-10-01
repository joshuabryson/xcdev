import Foundation
import Synchronization
import XcdevKit

/// Simulates xcodebuild and xcresulttool on a FakeProcessRunner. A build/test/clean run creates its
/// -resultBundlePath and remembers the outcome, which xcresulttool then reports for that bundle.
public final class FakeXcodebuild: Sendable {
    public struct Outcome: Sendable {
        public var exitCode: Int32
        public var log: String
        public var buildResults: String?
        public var testSummary: String?
        public var testTree: String?

        public init(exitCode: Int32 = 0, log: String = "** BUILD SUCCEEDED **\n", buildResults: String? = nil,
                    testSummary: String? = nil, testTree: String? = nil) {
            self.exitCode = exitCode
            self.log = log
            self.buildResults = buildResults
            self.testSummary = testSummary
            self.testTree = testTree
        }
    }

    private struct State {
        var next = Outcome()
        var bundles: [String: Outcome] = [:]
        var settings = "[]"
        var list = #"{"project":{"schemes":[]}}"#
        var runs: [Invocation] = []
    }

    private let state = Mutex(State())

    public init(runner: FakeProcessRunner) { install(on: runner) }

    public func onRun(_ outcome: Outcome) { state.withLock { $0.next = outcome } }
    public func onBuildSettings(_ json: String) { state.withLock { $0.settings = json } }
    public func onList(_ json: String) { state.withLock { $0.list = json } }
    /// build, test, and clean invocations, in order.
    public var runs: [Invocation] { state.withLock { $0.runs } }

    private func install(on runner: FakeProcessRunner) {
        runner.stub(["xcrun", "xcodebuild"]) { [self] inv in
            let args = inv.arguments
            if args.contains("-showsdks") { return ProcessOutput(stdout: FakeSimulators.sdksJSON) }
            if args.contains("-showBuildSettings") { return ProcessOutput(stdout: state.withLock { $0.settings }) }
            if args.contains("-list") { return ProcessOutput(stdout: state.withLock { $0.list }) }
            let outcome = state.withLock { st -> Outcome in
                st.runs.append(inv)
                return st.next
            }
            if let i = args.firstIndex(of: "-resultBundlePath"), i + 1 < args.count {
                try FileManager.default.createDirectory(atPath: args[i + 1], withIntermediateDirectories: true)
                state.withLock { $0.bundles[args[i + 1]] = outcome }
            }
            return ProcessOutput(exitCode: outcome.exitCode, stdout: outcome.log)
        }
        runner.stub(["xcrun", "xcresulttool", "get"]) { [self] inv in
            let args = inv.arguments
            guard let i = args.firstIndex(of: "--path"), i + 1 < args.count,
                  let outcome = state.withLock({ $0.bundles[args[i + 1]] }) else {
                return ProcessOutput(exitCode: 64, stderr: "Error: File or directory doesn't exist at path")
            }
            let body = args.contains("build-results") ? outcome.buildResults
                : args.contains("summary") ? outcome.testSummary : outcome.testTree
            return body.map { ProcessOutput(stdout: $0) } ?? ProcessOutput(exitCode: 1, stderr: "Error: no data")
        }
    }
}
