import Foundation
import Synchronization
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// How the service treats each runner failure code, a refusing runner, point waits, and the timeout clamp.
@Suite struct UIServiceFailureHandlingTests {
    let base = UIServiceTests()
    let options = UIOptions(device: nil, bundle: nil, system: false, role: nil, index: nil, timeout: .seconds(2))

    func tapError(_ failure: RunnerFailure, target: String = "id:x") async throws -> XcdError? {
        defer { base.worktree.remove() }
        var (service, ctx, _, _) = try base.setup { _, _ in FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.failure(failure)) }
        return await #expect(throws: XcdError.self) { _ = try await service.tap(target, options, in: &ctx) }
    }

    @Test func everyRunnerFailureCodeMapsToAnErrorWithANext() {
        let codes = [RunnerFailure.Code.notFound, RunnerFailure.Code.notHittable, RunnerFailure.Code.ambiguous, RunnerFailure.Code.staleRef,
                     RunnerFailure.Code.waitTimeout, RunnerFailure.Code.appNotForeground, RunnerFailure.Code.appCrashed, RunnerFailure.Code.badRequest,
                     RunnerFailure.Code.internal, "something_new"]
        #expect(Set(codes.dropLast()) == Set(UIRunnerErrors.mappers.keys))
        for code in codes {
            let error = UIRunnerErrors.error(RunnerFailure(code: code, message: "m"), target: "id:x", timeout: .seconds(1))
            #expect(error.next?.isEmpty == false, "\(code) has a next")
            #expect(error.code != .internalError, "\(code) is not generic")
        }
        let unknown = UIRunnerErrors.error(RunnerFailure(code: "something_new", message: "m"), target: "id:x", timeout: .seconds(1))
        #expect(unknown.code == .runnerFailed && unknown.message.contains("something_new"))
    }

    @Test func anAppThatIsNotInFrontSaysSoAndHowToFixIt() async throws {
        let error = try await tapError(RunnerFailure(code: RunnerFailure.Code.appNotForeground, message: "the app is in the background"))
        #expect(error?.code == .elementNotFound && error?.code.exitCode == 1)
        #expect(error?.message.contains("isn't in the foreground") == true && error?.message.contains("in the background") == true)
        #expect(error?.next == "bring the app to the foreground with `xcd launch` or `xcd run`, then retry")
    }

    @Test func badRequestAndInternalAreRunnerFailures() async throws {
        let bad = try await tapError(RunnerFailure(code: RunnerFailure.Code.badRequest, message: "unknown path /x"))
        #expect(bad?.code == .runnerFailed && bad?.code.exitCode == 3 && bad?.message.contains("unknown path /x") == true)
        #expect(bad?.next?.contains("xcd ui stop") == true)
        let inner = try await tapError(RunnerFailure(code: RunnerFailure.Code.internal, message: "the tap failed", issues: ["boom"]))
        #expect(inner?.code == .runnerFailed && inner?.code.exitCode == 3 && inner?.details == ["boom"] && inner?.next?.isEmpty == false)
    }

    @Test func aCoveredElementKeepsWhatCoversIt() async throws {
        let alert = try await tapError(RunnerFailure(code: RunnerFailure.Code.notHittable, message: "the element is covered by a system alert",
                                                     frame: ScreenRect(x: 1, y: 2, w: 3, h: 4)))
        #expect(alert?.code == .elementNotHittable && alert?.message == "id:x is covered by a system alert (1,2 3x4)")
        #expect(alert?.next?.contains("system alert") == true)
        let keyboard = try await tapError(RunnerFailure(code: RunnerFailure.Code.notHittable, message: "the element is covered by the keyboard"))
        #expect(keyboard?.message == "id:x is covered by the keyboard" && keyboard?.next?.contains("keyboard") == true)
    }

    @Test func anAmbiguousReplyNumbersItsCandidatesAndSaysTheyReplaceEarlierRefs() async throws {
        var one = UIServiceTests.element
        one.ref = "e1"
        var two = UIServiceTests.element
        two.ref = "e2"
        let error = try await tapError(RunnerFailure(code: RunnerFailure.Code.ambiguous, message: "2 elements match", candidates: [one, two]),
                                       target: "label:Sign In")
        #expect(error?.code == .elementAmbiguous && error?.details.count == 2)
        #expect(error?.details[0].hasPrefix("e1") == true && error?.details[1].hasPrefix("e2") == true)
        #expect(error?.next?.contains("`ref:eN`") == true && error?.next?.contains("replace any refs from an earlier tree") == true)
    }

    @Test func suggestionsCompareTheTargetsTextWithoutItsPrefix() async throws {
        let seen = ["Sign In", "signIn", "Email", "Welcome back"]
        for target in ["label~Emial", "label:Emial", "id:Emial"] {
            let error = try await tapError(RunnerFailure(code: RunnerFailure.Code.notFound, message: "no element matches", seen: seen), target: target)
            #expect(error?.message == "no element matches \(target)")
            #expect(error?.next == "closest on screen: Email; run `xcd ui tree` to see everything", "\(target)")
        }
    }

    @Test func anElementThatDidNotGoAwayIsStillOnScreenAfterTheTimeout() async throws {
        defer { base.worktree.remove() }
        var (service, ctx, _, _) = try base.setup { _, _ in
            FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.failure(
                RunnerFailure(code: RunnerFailure.Code.waitTimeout, message: "the element is still on screen")))
        }
        var three = options
        three.timeout = .seconds(3)
        let error = await #expect(throws: XcdError.self) { _ = try await service.wait("id:spinner", gone: true, three, in: &ctx) }
        #expect(error?.code == .waitTimeout && error?.message == "id:spinner is still on screen after 3.0s")
    }

    @Test func anUnknownRoleIsRefusedBeforeAnyRunnerStarts() async throws {
        defer { base.worktree.remove() }
        var (service, ctx, transport, detached) = try base.setup { _, _ in FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.success(ActionResult(element: nil, x: nil, y: nil, ms: 1))) }
        var wrong = options
        wrong.role = "buton"
        let tap = await #expect(throws: XcdError.self) { _ = try await service.tap("label:Sign In", wrong, in: &ctx) }
        #expect(tap?.code == .usage && tap?.message == "'buton' is not a role")
        #expect(tap?.next == "use one of: " + ElementRole.all.joined(separator: ", "))
        let wait = await #expect(throws: XcdError.self) { _ = try await service.wait("label:Sign In", gone: false, wrong, in: &ctx) }
        #expect(wait?.code == .usage && transport.calls.isEmpty && detached.starts.isEmpty)
        for role in ["button", "text", "cell", "other"] {
            var right = options
            right.role = role
            _ = try await service.tap("label:Sign In", right, in: &ctx)
        }
        #expect(transport.calls.filter { $0 == "/tap" }.count == 4)
    }

    @Test func theRoleNamesAreEveryRoleTheTreeCanShow() {
        #expect(ElementRole.all == ElementRole.all.sorted() && Set(ElementRole.all).count == ElementRole.all.count)
        #expect(Set(ElementRole.all) == Set(ElementRole.names.values).union(["other"]))
        #expect(ElementRole.interactive.isSubset(of: ElementRole.all) && ElementRole.structural.isSubset(of: ElementRole.all))
    }

    @Test func aTreeOfABackgroundAppSaysHowToGoOn() {
        func report(_ state: String) -> UITreeReport {
            var tree = UIServiceTests.tree
            tree.state = state
            return UITreeReport(device: "iphone", udid: "U", restarted: false, tree: tree, worktree: "feat")
        }
        #expect(report("background").text.hasSuffix("\nnext: bring it forward with `xcd launch`, or act on the Home Screen with `--system`"))
        #expect(report("not_running").text.hasSuffix("\nnext: start the app with `xcd run` or `xcd launch`"))
        #expect(!report("foreground").text.contains("next:") && !report("system").text.contains("next:"))
    }

    @Test func notHittableIsDescribedWithEveryReason() {
        #expect(ErrorCode.elementNotHittable.summary
            == "The element exists but is off screen, disabled, or covered by a system alert or the keyboard, so it wasn't acted on.")
    }

    @Test func aWaitForAPointIsRefusedBeforeAnyRunnerStarts() async throws {
        defer { base.worktree.remove() }
        var (service, ctx, transport, detached) = try base.setup { _, _ in FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.success(ActionResult(element: nil, x: nil, y: nil, ms: 1))) }
        let error = await #expect(throws: XcdError.self) { _ = try await service.wait("@10,20", gone: false, options, in: &ctx) }
        #expect(error?.code == .usage && error?.next?.isEmpty == false)
        #expect(transport.calls.isEmpty && detached.starts.isEmpty)
    }

    @Test func theTimeoutIsClampedToTwoMinutes() async throws {
        defer { base.worktree.remove() }
        let seen = Mutex<[Double]>([])
        var (service, ctx, _, _) = try base.setup { _, body in
            let request = try JSONDecoder().decode(TargetRequest.self, from: body ?? Data())
            seen.withLock { $0.append(request.timeout) }
            return FakeRunnerTransport.reply(Result<ActionResult, RunnerFailure>.failure(
                RunnerFailure(code: RunnerFailure.Code.waitTimeout, message: "the element did not appear")))
        }
        var long = options
        long.timeout = .seconds(900)
        let error = await #expect(throws: XcdError.self) { _ = try await service.wait("id:x", gone: false, long, in: &ctx) }
        #expect(seen.withLock { $0 } == [120] && error?.message == "id:x did not appear within 2m00s")
    }

    @Test func aRunnerThatRefusesARequestIsNotRestarted() async throws {
        defer { base.worktree.remove() }
        var (service, ctx, transport, detached) = try base.setup { _, _ in (400, Data()) }
        let error = await #expect(throws: XcdError.self) { _ = try await service.tree(all: false, options, in: &ctx) }
        #expect(error?.code == .runnerFailed && error?.message.contains("refused") == true)
        #expect(detached.starts.count == 1 && transport.calls.filter { $0 == "/tree" }.count == 1)
    }

    @Test func stopWithRebuildDiscardsTheBuildAfterStopping() async throws {
        defer { base.worktree.remove() }
        var (service, ctx, _, _) = try base.setup { _, _ in FakeRunnerTransport.reply(Result<TreeResult, RunnerFailure>.success(UIServiceTests.tree)) }
        _ = try await service.tree(all: false, options, in: &ctx)
        let report = try await service.stop(device: nil, rebuild: true, in: &ctx)
        #expect(report.text == "stopped the iphone UI runner\nthe UI runner will be rebuilt on next use")
        let xcode = try await service.supervisor.provisioner.ensureXcode(&ctx)
        #expect(!FileManager.default.fileExists(atPath: service.supervisor.builder.directory(for: xcode)))
    }
}
