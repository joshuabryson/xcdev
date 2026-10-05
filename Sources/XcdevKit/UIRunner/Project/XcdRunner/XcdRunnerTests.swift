import XCTest

/// XCTest issues recorded while a request runs, returned with its reply instead of failing the test.
final class IssueLog: @unchecked Sendable {
    static let shared = IssueLog()
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ text: String) {
        lock.lock()
        items.append(text)
        lock.unlock()
    }

    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let drained = items
        items = []
        return drained
    }
}

final class XcdRunnerTests: XCTestCase {
    // A failed gesture records an issue, and a recorded issue ends the test (and the server with it) whatever
    // `continueAfterFailure` says. Capturing issues here is what keeps the runner alive.
    override func record(_ issue: XCTIssue) {
        IssueLog.shared.add(issue.compactDescription)
    }

    /// The runner: starts the server, writes the ready file, then serves requests on the main thread until killed.
    @MainActor
    func testRun() throws {
        let environment = ProcessInfo.processInfo.environment
        let engine = RunnerEngine(device: XCUIDriver())
        engine.runnerBundleId = Bundle.main.bundleIdentifier ?? ""
        engine.rolesVerified = XCUIDriver.rolesVerified
        let health = engine.handle(path: RunnerProtocol.healthPath, body: Data())

        let token = environment["XCD_TOKEN"]
        if token?.isEmpty ?? true { NSLog("XCD_TOKEN is not set; refusing all requests") }
        let server = RunnerServer(token: token) { health }
        // The overridden `record` swallows issues, so a start-up error is logged here before it ends the test.
        do {
            let port = try server.start()
            if let ready = environment["XCD_READY_FILE"] {
                try FileManager.default.createDirectory(atPath: (ready as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try Data("{\"port\": \(port)}\n".utf8).write(to: URL(fileURLWithPath: ready), options: .atomic)
            }
            NSLog("XCD_READY port=\(port)")
        } catch {
            NSLog("XCD_RUNNER_FAILED: \(error)")
            throw error
        }

        while true {
            CFRunLoopRunInMode(.defaultMode, 1.0, false)
            while let job = server.next() {
                autoreleasepool {
                    // An issue recorded outside a request isn't this request's.
                    _ = IssueLog.shared.drain()
                    var reply = engine.handle(path: job.path, body: job.body)
                    let issues = IssueLog.shared.drain()
                    if !issues.isEmpty { reply = Self.adding(issues, to: reply) }
                    // Free the slot first: once the client has the reply its next request may arrive at once.
                    server.finished()
                    job.reply(200, reply)
                }
            }
        }
    }

    /// Puts recorded XCTest issues into a failed reply, or turns a successful one into an `internal` failure.
    static func adding(_ issues: [String], to reply: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else { return reply }
        var failure = object["failure"] as? [String: Any]
            ?? ["code": RunnerFailure.Code.internal, "message": "XCTest reported a problem", "candidates": [Any](), "seen": [String]()]
        failure["issues"] = issues
        object["failure"] = failure
        object["ok"] = false
        object["result"] = nil
        return (try? JSONSerialization.data(withJSONObject: object)) ?? reply
    }
}
