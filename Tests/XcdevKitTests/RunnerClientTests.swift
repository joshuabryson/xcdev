import Foundation
import Synchronization
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct RunnerClientTests {
    private let treeRequest = TreeRequest(bundleId: "b", system: false, all: false)

    private func callTree(status: Int, body: String) async -> XcdError? {
        let transport = FakeRunnerTransport { _, _ in (status, Data(body.utf8)) }
        let request = treeRequest
        return await #expect(throws: XcdError.self) {
            _ = try await RunnerClient(transport: transport).call(RunnerProtocol.treePath, request, port: 1, token: "t",
                                                                  timeout: .seconds(5), as: TreeResult.self)
        }
    }

    @Test func healthIsNilUnlessACurrentRunnerAnswers() async {
        #expect(await RunnerClient(transport: FakeRunnerTransport()).health(port: 1, token: "t")?.runner == RunnerSource.runnerBundleId)
        let refused = FakeRunnerTransport { _, _ in throw RunnerUnreachable(reason: "connection refused") }
        #expect(await RunnerClient(transport: refused).health(port: 1, token: "t") == nil)
        let old = FakeRunnerTransport { _, _ in
            FakeRunnerTransport.reply(Result<HealthInfo, RunnerFailure>.success(HealthInfo(protocolVersion: 0, runner: "x", rolesVerified: true)))
        }
        #expect(await RunnerClient(transport: old).health(port: 1, token: "t") == nil)
        let rejected = FakeRunnerTransport { _, _ in (401, Data()) }
        #expect(await RunnerClient(transport: rejected).health(port: 1, token: "t") == nil)
        let garbage = FakeRunnerTransport { _, _ in (200, Data("not json".utf8)) }
        #expect(await RunnerClient(transport: garbage).health(port: 1, token: "t") == nil)
    }

    @Test func healthAsksTheHealthPathOnce() async {
        let transport = FakeRunnerTransport()
        _ = await RunnerClient(transport: transport).health(port: 1, token: "t")
        #expect(transport.calls == [RunnerProtocol.healthPath])
    }

    @Test func aCallDecodesTheResultOrTheRunnersFailure() async throws {
        let result = ActionResult(element: nil, x: 1, y: 2, ms: 5)
        let ok = FakeRunnerTransport { _, _ in FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.success(result)) }
        let request = TargetRequest(bundleId: "b", system: false, target: .point(x: 1, y: 2), role: nil, index: nil, timeout: 2, gone: false)
        #expect(try await RunnerClient(transport: ok).call(RunnerProtocol.tapPath, request, port: 1, token: "t", timeout: .seconds(5),
                                                           as: ActionResult.self).get() == result)
        #expect(ok.calls == ["/tap"])
        let failing = FakeRunnerTransport { _, _ in
            FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.failure(RunnerFailure(code: RunnerFailure.Code.notFound, message: "no")))
        }
        let outcome = try await RunnerClient(transport: failing).call(RunnerProtocol.tapPath, request, port: 1, token: "t",
                                                                      timeout: .seconds(5), as: ActionResult.self)
        guard case .failure(let failure) = outcome else { Issue.record("succeeded"); return }
        #expect(failure.code == RunnerFailure.Code.notFound)
    }

    @Test func aCallSendsTheEncodedRequestBody() async throws {
        let seen = Mutex<Data?>(nil)
        let transport = FakeRunnerTransport { _, body in
            seen.withLock { $0 = body }
            return FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.success(ActionResult(element: nil, x: nil, y: nil, ms: 0)))
        }
        let request = treeRequest
        _ = try await RunnerClient(transport: transport).call(RunnerProtocol.tapPath, request, port: 1, token: "t",
                                                              timeout: .seconds(5), as: ActionResult.self)
        let sent = try #require(seen.withLock { $0 })
        #expect(try JSONDecoder().decode(TreeRequest.self, from: sent) == request)
    }

    @Test func aReplyWithNeitherResultNorFailureIsAnInternalFailure() async throws {
        let transport = FakeRunnerTransport { _, _ in (200, Data(#"{"ok":false}"#.utf8)) }
        let request = treeRequest
        let outcome = try await RunnerClient(transport: transport).call(RunnerProtocol.treePath, request, port: 1, token: "t",
                                                                        timeout: .seconds(5), as: TreeResult.self)
        guard case .failure(let failure) = outcome else { Issue.record("succeeded"); return }
        #expect(failure.code == RunnerFailure.Code.internal)
    }

    @Test func busyRejectedAndUnreadableRepliesAreRunnerFailed() async {
        let busy = await callTree(status: 409, body: "{}")
        #expect(busy?.code == .runnerFailed && busy?.message == "another ui command is running in this worktree")
        #expect(busy?.next == "wait for it to finish, then retry")
        let rejected = await callTree(status: 401, body: "{}")
        #expect(rejected?.code == .runnerFailed && rejected?.message == "the UI runner rejected xcd's token")
        #expect(rejected?.next == "run `xcd ui stop`, then retry")
        let unreadable = await callTree(status: 200, body: "not json")
        #expect(unreadable?.code == .runnerFailed && unreadable?.message == "the UI runner sent a reply xcd could not read")
        #expect(unreadable?.details == ["not json"])
        #expect(unreadable?.next != nil)
    }

    @Test func aRunnerThatRefusesTheRequestIsRunnerFailedNotUnreachable() async {
        // The runner answered (400 malformed, 413 too large), so restarting it would not help.
        for status in [400, 413] {
            let error = await callTree(status: status, body: #"{"ok":false}"#)
            #expect(error?.code == .runnerFailed, "status \(status)")
            #expect(error?.message == "the UI runner refused the request (HTTP \(status))", "status \(status)")
            // The refusal is deterministic, so the advice is not to retry the same request.
            #expect(error?.next == "this is likely an xcd bug; run `xcd ui stop`, then retry", "status \(status)")
        }
    }

    @Test func anUnexpectedStatusMeansTheRunnerIsUnreachable() async {
        let transport = FakeRunnerTransport { _, _ in (503, Data()) }
        let request = treeRequest
        let error = await #expect(throws: RunnerUnreachable.self) {
            _ = try await RunnerClient(transport: transport).call(RunnerProtocol.treePath, request, port: 1, token: "t",
                                                                  timeout: .seconds(5), as: TreeResult.self)
        }
        #expect(error == RunnerUnreachable(reason: "HTTP 503"))
    }

    @Test func aRunnerThatDoesNotAnswerIsUnreachableNotAnXcdError() async {
        let transport = FakeRunnerTransport { _, _ in throw RunnerUnreachable(reason: "refused") }
        await #expect(throws: RunnerUnreachable.self) {
            _ = try await RunnerClient(transport: transport).call(RunnerProtocol.treePath, TreeRequest(bundleId: nil, system: true, all: false),
                                                                  port: 1, token: "t", timeout: .seconds(5), as: TreeResult.self)
        }
        let error = await #expect(throws: RunnerUnreachable.self) {
            _ = try await URLSessionRunnerTransport().send(port: 1, token: "t", path: "/health", body: nil, timeout: .seconds(2))
        }
        #expect(error != nil)                       // nothing listens on port 1
    }
}
