import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The look `xcd open` makes for a route's `expect`, through the UI runner.
@Suite struct UIArrivalTests {
    let base = UIServiceTests()

    /// Looks for `id:signIn` with a runner that answers `answer`. Returns what was seen and the request the runner got.
    func look(_ answer: Result<ActionResult, RunnerFailure>, timeout: Duration = .seconds(10)) async throws -> (ArrivalSight, TargetRequest) {
        let sent = SentRequests()
        var (service, ctx, _, _) = try base.setup { path, body in
            sent.add(path, body ?? Data())
            return FakeRunnerTransport.reply(answer)
        }
        let sight = try await service.look(for: "id:signIn", timeout: timeout, device: "iphone", in: &ctx)
        let (path, request) = try sent.last(as: TargetRequest.self)
        #expect(path == RunnerProtocol.waitPath)
        return (sight, request)
    }

    @Test func anElementThatIsThereIsFound() async throws {
        defer { base.worktree.remove() }
        let (sight, request) = try await look(.success(ActionResult(element: UIServiceTests.element, x: nil, y: nil, ms: 812)))
        #expect(sight == .found(seconds: 0.812))
        #expect(request.bundleId == "dev.xcdev.App" && !request.system && request.target == .id("signIn"))
        #expect(request.timeout == 10 && request.gone == false)
    }

    /// A look before a delivery asks for no waiting at all.
    @Test func aLookWithNoTimeoutAsksTheRunnerNotToWait() async throws {
        defer { base.worktree.remove() }
        let (sight, request) = try await look(.failure(RunnerFailure(code: RunnerFailure.Code.waitTimeout, message: "the element did not appear",
                                                                     seen: ["Welcome"])), timeout: .zero)
        #expect(sight == .missing(onScreen: ["Welcome"], away: nil) && request.timeout == 0)
    }

    /// The runner keeps looking while the app is away and then says so: that is where a link that opened Safari ends.
    @Test func anAppThatIsNotInFrontIsMissingAndSaysWhy() async throws {
        defer { base.worktree.remove() }
        let away = RunnerFailure(code: RunnerFailure.Code.appNotForeground, message: "the app is in the background")
        #expect(try await look(.failure(away)).0 == .missing(onScreen: [], away: "the app is in the background"))
    }

    @Test func aRunnerThatFailsThrows() async throws {
        defer { base.worktree.remove() }
        let broken = RunnerFailure(code: RunnerFailure.Code.internal, message: "the wait failed: snapshot failed")
        let error = await #expect(throws: XcdError.self) { _ = try await look(.failure(broken)) }
        #expect(error?.code == .runnerFailed && error?.message == "the wait failed: snapshot failed")
    }

    @Test func aWorktreeWithNoBuildHasNoAppToLookIn() async throws {
        defer { base.worktree.remove() }
        var (service, ctx, _, _) = try base.setup { _, _ in FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.success(ActionResult(element: nil, x: nil, y: nil, ms: 1))) }
        try AppStateStore.save(AppState(), ctx.paths)
        let error = await #expect(throws: XcdError.self) { _ = try await service.look(for: "id:signIn", timeout: .zero, device: "iphone", in: &ctx) }
        #expect(error?.code == .appNotBuilt)
    }
}
