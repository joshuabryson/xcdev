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
        let raw = try Summary.decode(summary)
        var failures = tests.flatMap(treeFailures) ?? []
        // The tree has locations; the summary is authoritative about which tests failed.
        let inTree = Set(failures.map(\.test))
        for failure in raw.testFailures ?? [] {
            let test = failure.testIdentifierURL.map(testIdentifier(fromURL:)) ?? failure.testIdentifierString ?? "?"
            if !inTree.contains(test) {
                failures.append(TestFailure(test: test, message: failure.failureText, file: nil, line: nil))
            }
        }
        return TestResults(counts: raw.counts, failures: failures)
    }

    private struct Summary: Decodable {
        struct Failure: Decodable { let failureText: String; let testIdentifierURL: String?; let testIdentifierString: String? }
        let totalTestCount: Int?
        let passedTests: Int?
        let failedTests: Int?
        let skippedTests: Int?
        let expectedFailures: Int?
        let testFailures: [Failure]?

        var counts: TestCounts {
            TestCounts(total: totalTestCount ?? 0, passed: passedTests ?? 0, failed: failedTests ?? 0,
                       skipped: skippedTests ?? 0, expectedFailures: expectedFailures ?? 0)
        }

        static func decode(_ data: Data) throws -> Summary {
            do {
                return try JSONDecoder().decode(Summary.self, from: data)
            } catch {
                throw XcdError(.subprocessFailed, "could not parse `xcresulttool get test-results summary` output",
                               details: ["\(error)"])
            }
        }
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
                            failures.append(failure(child, of: id))
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

    private static func failure(_ message: Node, of test: String) -> TestFailure {
        let text = message.name ?? ""
        if message.sourceLocation == nil, let located = failure(of: test, locatedByItsText: text) { return located }
        return TestFailure(test: test, message: text, file: message.sourceLocation?.filePath, line: message.sourceLocation?.lineNumber)
    }
}

extension TestResults {
    /// Whether a failure names its file without the folder, as Xcode 26 does.
    var needsPlacing: Bool { failures.contains { $0.file.map { !$0.hasPrefix("/") } ?? false } }

    /// Each failure's bare file name made the file's path, when exactly one of `files` (relative to `root`) has
    /// that name. A name two files share, or none has, is kept as Xcode gave it.
    func placing(_ files: [String], under root: String) -> TestResults {
        let byName = Dictionary(grouping: files) { ($0 as NSString).lastPathComponent }
        return TestResults(counts: counts, failures: failures.map { failure in
            guard let file = failure.file, !file.hasPrefix("/"), let only = byName[file], only.count == 1 else { return failure }
            return TestFailure(test: failure.test, message: failure.message, file: root + "/" + only[0], line: failure.line)
        })
    }

    /// Xcode 26 gives a failure no location and starts its text with one instead, the file without its folder:
    /// "SampleAppTests.swift:9: Expectation failed: …". Nil for a text that doesn't start that way.
    static func failure(of test: String, locatedByItsText text: String) -> TestFailure? {
        let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1].allSatisfy({ ("0"..."9").contains($0) }), let line = Int(parts[1]),
              parts[2].hasPrefix(" "), !parts[0].contains("\n"), !(String(parts[0]) as NSString).pathExtension.isEmpty
        else { return nil }
        return TestFailure(test: test, message: String(parts[2].dropFirst()), file: String(parts[0]), line: line)
    }
}
