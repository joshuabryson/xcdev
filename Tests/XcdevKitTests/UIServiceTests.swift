import Foundation
import Synchronization
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct UIServiceTests {
    let supervisorTests = RunnerSupervisorTests()
    var worktree: FakeWorktree { supervisorTests.worktree }
    static let element = TreeElement(ref: "e1", role: "button", label: "Sign In", identifier: "signIn", value: nil, placeholder: nil,
                                     frame: ScreenRect(x: 24, y: 700, w: 354, h: 50), depth: 3, enabled: true, selected: false,
                                     source: .app, offscreen: false, window: 0)
    static let tree = TreeResult(bundleId: "dev.xcdev.App", state: "foreground", screen: ScreenRect(x: 0, y: 0, w: 402, h: 874),
                                 scale: 3, orientation: "portrait", keyboard: false, elements: [
        element,
        TreeElement(ref: "e2", role: "textField", label: "", identifier: "email", value: "", placeholder: "Email",
                    frame: ScreenRect(x: 24, y: 300, w: 354, h: 44), depth: 3, enabled: true, selected: false, source: .app,
                    offscreen: false, window: 0),
        TreeElement(ref: "e3", role: "button", label: "Allow", identifier: "", value: nil, placeholder: nil,
                    frame: ScreenRect(x: 57, y: 457, w: 288, h: 48), depth: 1, enabled: false, selected: true, source: .system,
                    offscreen: false, window: 0),
    ])

    func setup(_ handler: @escaping FakeRunnerTransport.Handler) throws -> (UIService, WorktreeContext, FakeRunnerTransport, FakeDetachedProcesses) {
        let transport = FakeRunnerTransport { path, body in
            path == RunnerProtocol.healthPath ? try FakeRunnerTransport.healthy(path, body) : try handler(path, body)
        }
        let detached = FakeDetachedProcesses(onStart: RunnerSupervisorTests.writesReady)
        let (supervisor, ctx) = try supervisorTests.setup(detached: detached, transport: transport)
        var state = AppState()
        state.builds["iphone"] = BuildRecord(scheme: "App", configuration: nil,
                                             product: AppProduct(path: "/A.app", bundleId: "dev.xcdev.App", executableName: "App", platform: "iphonesimulator"),
                                             finishedAt: Date())
        try AppStateStore.save(state, ctx.paths)
        return (UIService(supervisor: supervisor, client: supervisor.client), ctx, transport, detached)
    }

    let options = UIOptions(device: nil, bundle: nil, system: false, role: nil, index: nil, timeout: .seconds(2))

    @Test func theTreeReportHasTheDocumentedShape() async throws {
        defer { worktree.remove() }
        var (service, ctx, transport, _) = try setup { _, body in
            let request = try JSONDecoder().decode(TreeRequest.self, from: body ?? Data())
            #expect(request == TreeRequest(bundleId: "dev.xcdev.App", system: false, all: false))
            return FakeRunnerTransport.reply(Result<TreeResult, RunnerFailure>.success(Self.tree))
        }
        let report = try await service.tree(all: false, options, in: &ctx)
        #expect(report.text == """
        app dev.xcdev.App (foreground)  screen 402x874pt @3x  portrait  keyboard: hidden
        e1  button     "Sign In"  id=signIn  24,700 354x50
        e2  textField  (no label)  value=""  placeholder="Email"  id=email  24,300 354x44
        e3  button     "Allow"  57,457 288x48  disabled  selected  system
        """)
        #expect(transport.calls == ["/health", "/tree"])
        #expect(report.device == "iphone" && !report.restarted)
    }

    @Test func theBundleComesFromTheBuildABundleFlagOrSystem() async throws {
        defer { worktree.remove() }
        let seen = Mutex<[TreeRequest]>([])
        var (service, ctx, _, _) = try setup { _, body in
            seen.withLock { $0.append(try! JSONDecoder().decode(TreeRequest.self, from: body ?? Data())) }
            return FakeRunnerTransport.reply(Result<TreeResult, RunnerFailure>.success(Self.tree))
        }
        var custom = options
        custom.bundle = "com.apple.Preferences"
        _ = try await service.tree(all: true, custom, in: &ctx)
        var system = options
        system.system = true
        _ = try await service.tree(all: false, system, in: &ctx)
        #expect(seen.withLock { $0 } == [TreeRequest(bundleId: "com.apple.Preferences", system: false, all: true),
                                         TreeRequest(bundleId: nil, system: true, all: false)])
        try AppStateStore.save(AppState(), ctx.paths)                      // no build
        let error = await #expect(throws: XcdError.self) { _ = try await service.tree(all: false, options, in: &ctx) }
        #expect(error?.code == .appNotBuilt)
        #expect(error?.next == "pass --bundle <id>, use --system for the Home Screen, or build first with `xcd build --device iphone`")
    }

    @Test func aTapReportsWhatItHit() async throws {
        defer { worktree.remove() }
        var (service, ctx, _, _) = try setup { _, body in
            let request = try JSONDecoder().decode(TargetRequest.self, from: body ?? Data())
            #expect(request.target == .label("Sign In") && request.role == "button" && request.timeout == 2 && !request.gone)
            return FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.success(ActionResult(element: Self.element, x: 201, y: 725, ms: 812)))
        }
        var withRole = options
        withRole.role = "button"
        let report = try await service.tap("label:Sign In", withRole, in: &ctx)
        #expect(report.text == #"tapped button "Sign In" id=signIn at 201,725  812ms"#)
        let bad = await #expect(throws: XcdError.self) { _ = try await service.tap("Sign In", options, in: &ctx) }
        #expect(bad?.code == .usage && bad?.next == "use " + TargetParser.forms)
    }

    @Test func runnerFailuresBecomeErrorsThatSayWhatToDo() async throws {
        defer { worktree.remove() }
        let failure = Mutex(RunnerFailure(code: RunnerFailure.Code.notFound, message: "no element matches",
                                          seen: ["Sign In", "signIn", "Email", "Welcome back"]))
        var (service, ctx, _, _) = try setup { _, _ in
            FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.failure(failure.withLock { $0 }))
        }
        func error(_ target: String = "label:Sign Inn") async -> XcdError? {
            await #expect(throws: XcdError.self) { _ = try await service.tap(target, options, in: &ctx) }
        }
        let notFound = await error()
        #expect(notFound?.code == .elementNotFound && notFound?.message == "no element matches label:Sign Inn")
        #expect(notFound?.next == "closest on screen: Sign In, signIn; run `xcd ui tree` to see everything")

        failure.withLock { $0 = RunnerFailure(code: RunnerFailure.Code.notHittable, message: "the element is off screen",
                                              frame: ScreenRect(x: 24, y: 3574, w: 100, h: 44)) }
        let offscreen = await error("id:far")
        #expect(offscreen?.code == .elementNotHittable && offscreen?.message == "id:far is off screen (24,3574 100x44)")
        #expect(offscreen?.next == "scroll it into view, then retry; `xcd ui tree --all` lists off-screen elements")

        failure.withLock { $0 = RunnerFailure(code: RunnerFailure.Code.ambiguous, message: "2 elements match", candidates: [Self.element, Self.element]) }
        let ambiguous = await error("label:Delete")
        #expect(ambiguous?.code == .elementAmbiguous && ambiguous?.details.count == 2)
        #expect(ambiguous?.next == "pick one: pass `ref:eN` (or just `eN`) from the list, `--index <n>` (0 is the first), or `--role <role>`")

        failure.withLock { $0 = RunnerFailure(code: RunnerFailure.Code.staleRef, message: "that ref no longer names one element on screen") }
        let gone = await error("ref:e9")
        #expect(gone?.code == .staleRef && gone?.message == "ref:e9 no longer names one element on screen")
        #expect(gone?.next == "run `xcd ui tree` and use a ref from it")
        // A ref of an earlier tree, as an agent that kept one would give it: the answer says why it is refused.
        failure.withLock { $0 = RunnerFailure(code: RunnerFailure.Code.staleRef, message: RunnerEngine.unknownRef) }
        let unknown = await error("e5")
        #expect(unknown?.code == .staleRef && unknown?.message == "e5 is not a ref of the latest tree")
        #expect(unknown?.next == "a ref lasts while each new tree lists its element; run `xcd ui tree` and use a ref from it, "
                + "or aim with `id:` or `label:`, which need no tree")

        failure.withLock { $0 = RunnerFailure(code: RunnerFailure.Code.internal, message: "the tap failed", issues: ["Failed to tap"]) }
        let inner = await error("id:x")
        #expect(inner?.code == .runnerFailed && inner?.details == ["Failed to tap"])
    }

    @Test func aWaitReportsWhatItFoundOrTimesOut() async throws {
        defer { worktree.remove() }
        let gone = Mutex(false)
        var (service, ctx, _, _) = try setup { _, body in
            let request = try JSONDecoder().decode(TargetRequest.self, from: body ?? Data())
            gone.withLock { $0 = request.gone }
            if request.timeout == 1 {
                return FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.failure(
                    RunnerFailure(code: RunnerFailure.Code.waitTimeout, message: "the element did not appear", seen: ["Sign In", "Email"])))
            }
            return FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.success(
                ActionResult(element: request.gone ? nil : Self.element, x: nil, y: nil, ms: 320)))
        }
        #expect(try await service.wait("id:signIn", gone: false, options, in: &ctx).text == #"found button "Sign In" id=signIn after 320ms"#)
        #expect(try await service.wait("id:spinner", gone: true, options, in: &ctx).text == "id:spinner is gone after 320ms")
        #expect(gone.withLock { $0 })
        var short = options
        short.timeout = .seconds(1)
        let error = await #expect(throws: XcdError.self) { _ = try await service.wait("id:later", gone: false, short, in: &ctx) }
        #expect(error?.code == .waitTimeout && error?.message == "id:later did not appear within 1.0s")
        #expect(error?.next == "on screen now: Sign In, Email; run `xcd ui tree`")
    }

    @Test func aDeadRunnerIsRestartedAndAReadIsSentAgain() async throws {
        defer { worktree.remove() }
        let calls = Counter()
        var (service, ctx, _, detached) = try setup { _, _ in
            if calls.increment() == 1 { throw RunnerUnreachable(reason: "refused") }
            return FakeRunnerTransport.reply(Result<TreeResult, RunnerFailure>.success(Self.tree))
        }
        let report = try await service.tree(all: false, options, in: &ctx)
        #expect(report.restarted && detached.starts.count == 2 && calls.value == 2)
        #expect(report.text.hasSuffix("note: the UI runner was restarted, so refs from earlier trees are gone"))
    }

    @Test func anActionIsNotSentAgainAfterARestart() async throws {
        defer { worktree.remove() }
        let calls = Counter()
        var (service, ctx, _, detached) = try setup { _, _ in
            calls.increment()
            throw RunnerUnreachable(reason: "refused")
        }
        let error = await #expect(throws: XcdError.self) { _ = try await service.tap("@1,2", options, in: &ctx) }
        #expect(error?.code == .runnerFailed)
        #expect(error?.message == "the UI runner stopped answering during the tap, so it may or may not have happened")
        #expect(error?.next == "check with `xcd ui tree`; the runner has been restarted")
        #expect(calls.value == 1 && detached.starts.count == 2)            // sent once; the runner was replaced
    }

    @Test func stopReportsWhatItStoppedAndCanDiscardTheBuild() async throws {
        defer { worktree.remove() }
        var (service, ctx, _, _) = try setup { _, _ in FakeRunnerTransport.reply(Result<TreeResult, RunnerFailure>.success(Self.tree)) }
        _ = try await service.tree(all: false, options, in: &ctx)
        #expect(try await service.stop(device: nil, rebuild: false, in: &ctx).text == "stopped the iphone UI runner")
        #expect(try await service.stop(device: nil, rebuild: false, in: &ctx).text == "no UI runner was running for iphone")
        let rebuilt = try await service.stop(device: nil, rebuild: true, in: &ctx)
        #expect(rebuilt.text == "no UI runner was running for iphone\nthe UI runner will be rebuilt on next use")
    }
}
