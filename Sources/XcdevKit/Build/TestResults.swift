import Foundation

public struct TestFailure: Codable, Sendable, Equatable {
    /// The `-only-testing` identifier, e.g. "SampleAppTests/failsOnPurpose()".
    public let test: String
    public let message: String
    public let file: String?
    public let line: Int?

    public init(test: String, message: String, file: String?, line: Int?) {
        self.test = test
        self.message = message
        self.file = file
        self.line = line
    }

    public var diagnostic: Diagnostic { Diagnostic(.error, "\(test): \(message)", file: file, line: line) }
}

public struct TestCounts: Codable, Sendable, Equatable {
    public let total: Int
    public let passed: Int
    public let failed: Int
    public let skipped: Int
    public let expectedFailures: Int

    public init(total: Int, passed: Int, failed: Int, skipped: Int, expectedFailures: Int) {
        self.total = total
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.expectedFailures = expectedFailures
    }
}

/// `xcresulttool get test-results summary` plus, for failure locations, `get test-results tests`.
public struct TestResults: Sendable, Equatable {
    public let counts: TestCounts
    public let failures: [TestFailure]

    public static func parse(summary: Data, tests: Data?) throws -> TestResults {
        struct SummaryFailure: Decodable { let failureText: String; let testIdentifierURL: String?; let testIdentifierString: String? }
        struct Summary: Decodable {
            let totalTestCount: Int?
            let passedTests: Int?
            let failedTests: Int?
            let skippedTests: Int?
            let expectedFailures: Int?
            let testFailures: [SummaryFailure]?
        }
        let raw: Summary
        do {
            raw = try JSONDecoder().decode(Summary.self, from: summary)
        } catch {
            throw XcdError(.subprocessFailed, "could not parse `xcresulttool get test-results summary` output",
                           details: ["\(error)"])
        }
        let counts = TestCounts(total: raw.totalTestCount ?? 0, passed: raw.passedTests ?? 0, failed: raw.failedTests ?? 0,
                                skipped: raw.skippedTests ?? 0, expectedFailures: raw.expectedFailures ?? 0)
        var failures = tests.flatMap(treeFailures) ?? []
        // The tree has locations; the summary is authoritative about which tests failed.
        let inTree = Set(failures.map(\.test))
        for failure in raw.testFailures ?? [] {
            let test = failure.testIdentifierURL.map(testIdentifier(fromURL:)) ?? failure.testIdentifierString ?? "?"
            if !inTree.contains(test) {
                failures.append(TestFailure(test: test, message: failure.failureText, file: nil, line: nil))
            }
        }
        return TestResults(counts: counts, failures: failures)
    }

    /// "test://com.apple.xcode/<project>/<Target>/<Class>/<test>" → "<Target>/<Class>/<test>".
    public static func testIdentifier(fromURL url: String) -> String {
        let trimmed = url.hasPrefix("test://") ? String(url.dropFirst("test://".count)) : url
        return trimmed.split(separator: "/", omittingEmptySubsequences: false).dropFirst(2).joined(separator: "/")
    }

    private struct Node: Decodable {
        let name: String?
        let nodeType: String?
        let nodeIdentifierURL: String?
        let result: String?
        let sourceLocation: Location?
        let children: [Node]?
        struct Location: Decodable { let filePath: String?; let lineNumber: Int? }
    }

    /// One failure per "Failure Message" anywhere under a failed "Test Case" (arguments, repetitions and
    /// test-case runs may sit in between), with its source location.
    private static func treeFailures(_ data: Data) -> [TestFailure]? {
        struct Tree: Decodable { let testNodes: [Node] }
        guard let tree = try? JSONDecoder().decode(Tree.self, from: data) else { return nil }
        var failures: [TestFailure] = []
        func walk(_ node: Node) {
            if node.nodeType == "Test Case", node.result == "Failed" {
                let id = node.nodeIdentifierURL.map(testIdentifier(fromURL:)) ?? node.name ?? "?"
                func collect(_ node: Node) {
                    for child in node.children ?? [] {
                        if child.nodeType == "Failure Message" {
                            failures.append(TestFailure(test: id, message: child.name ?? "",
                                                        file: child.sourceLocation?.filePath, line: child.sourceLocation?.lineNumber))
                        } else {
                            collect(child)
                        }
                    }
                }
                collect(node)
                return
            }
            node.children?.forEach(walk)
        }
        tree.testNodes.forEach(walk)
        return failures
    }
}
