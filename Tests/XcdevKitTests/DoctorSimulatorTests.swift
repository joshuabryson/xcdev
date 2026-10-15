import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// `xcd doctor`'s templates and CoreSimulator checks.
@Suite struct DoctorSimulatorTests: DoctorFixture {
    let fake = FakeProcessRunner()

    @Test func templatesMustBeShutDownAvailableAndUnique() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        let booted = sims.add(name: "xcd-template · iPhone 18 Pro · iOS 27.0", state: "Booted")
        let duplicate = "xcd-template · iPhone 16 · iOS 27.0"
        sims.add(name: duplicate)
        sims.add(name: duplicate, state: "Booted")
        let gone = sims.add(name: "xcd-template · iPhone 16 · iOS 26.5", isAvailable: false)
        let report = await doctor(project).run(fix: true, checks: [TemplatesCheck()], from: nil)
        #expect(report.problems.count == 3 && report.problems.allSatisfy { $0.fixed })
        let left = sims.devices.filter { $0.name.hasPrefix(SimNaming.templatePrefix) }
        #expect(left.filter { $0.name == duplicate }.map(\.state) == ["Shutdown"])      // the usable copy is kept
        #expect(left.first { $0.udid == booted }?.state == "Shutdown")
        #expect(!left.contains { $0.udid == gone })
    }

    @Test func templateProblemsAreOnlyReportedWithoutFix() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        sims.add(name: "xcd-template · iPhone 18 Pro · iOS 27.0", state: "Booted")
        let before = sims.devices
        let report = await doctor(project).run(fix: false, checks: [TemplatesCheck()], from: nil)
        #expect(report.problems.count == 1 && !report.problems[0].fixed)
        #expect(sims.devices == before)
        #expect(report.failure?.next == "run `xcd doctor --fix` to fix 1 of them")
    }

    /// Doctor's CoreSimulator check with its fix, where `pkill` restarts the service and counts in `restarted`.
    /// Returns the check's one problem.
    func restart(_ project: TempProject, counting restarted: Counter) async throws -> DoctorProblem {
        fake.stub(["pkill"]) { _ in restarted.increment(); return ProcessOutput() }
        let report = await doctor(project).run(fix: true, checks: [CoreSimulatorCheck()], from: nil)
        return try #require(report.problems.first)
    }

    @Test func anUnresponsiveCoreSimulatorIsRestarted() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let listing = Fixture.string("simctl-list.json")
        let restarted = Counter()
        fake.stub(["xcrun", "simctl", "list", "-j"]) { _ in
            restarted.value == 0 ? ProcessOutput(exitCode: 1, stderr: "Failed to initialize simulator device set.")
                                 : ProcessOutput(stdout: listing)
        }
        let problem = try await restart(project, counting: restarted)
        #expect(problem.message == "CoreSimulator didn't answer `simctl list`: `xcrun simctl list` failed (exit 1): Failed to initialize simulator device set.")
        #expect(problem.fixed)
        #expect(fake.calls.contains { $0.argv == ["pkill", "-9", "-f", "com.apple.CoreSimulator.CoreSimulatorService"] })
    }

    @Test func aPersistentCoreSimulatorFailureIsOnlyReportedWithoutFix() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        fake.stub(["xcrun", "simctl", "list", "-j"], exitCode: 1, stderr: "Failed to initialize simulator device set.")
        fake.stub(["pkill"]) { _ in ProcessOutput() }
        let report = await doctor(project).run(fix: false, checks: [CoreSimulatorCheck()], from: nil)
        let problem = try #require(report.problems.first)
        #expect(problem.action == .restartCoreSimulator && !problem.fixed)
        #expect(fake.calls.filter { $0.argv == ["xcrun", "simctl", "list", "-j"] }.count == CoreSimulatorCheck.listAttempts)
        #expect(pkillCalls == 0)
        #expect(report.failure?.code == .doctorProblems)
    }

    /// One failed list is retried, so a blip never restarts CoreSimulator.
    @Test func aTransientListFailureIsRetriedNotRestarted() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let listing = Fixture.string("simctl-list.json")
        let lists = Counter()
        fake.stub(["xcrun", "simctl", "list", "-j"]) { _ in
            lists.increment() == 1 ? ProcessOutput(exitCode: 1, stderr: "Failed to initialize simulator device set.")
                                   : ProcessOutput(stdout: listing)
        }
        fake.stub(["pkill"]) { _ in ProcessOutput() }
        let report = await doctor(project).run(fix: true, checks: [CoreSimulatorCheck()], from: nil)
        #expect(report.problems.isEmpty && report.failure == nil)
        #expect(pkillCalls == 0)
    }

    /// A list that fails for a reason other than CoreSimulator (here xcrun can't find simctl) is reported with a
    /// `next:` line, and `--fix` doesn't restart CoreSimulator for it.
    @Test func aFailureOutsideCoreSimulatorIsNotFixedByRestarting() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        fake.stub(["xcrun", "simctl", "list", "-j"], exitCode: 72,
                  stderr: "xcrun: error: unable to find utility \"simctl\", not a developer tool or in PATH")
        fake.stub(["pkill"]) { _ in ProcessOutput() }
        let report = await doctor(project).run(fix: true, checks: [CoreSimulatorCheck()], from: nil)
        let problem = try #require(report.problems.first)
        #expect(problem.action == nil && problem.next != nil && !problem.fixed)
        #expect(problem.message.hasPrefix("simctl couldn't list simulators: `xcrun simctl list` failed (exit 72): xcrun: error:"))
        #expect(pkillCalls == 0)
    }

    /// Simctl answered, but its JSON didn't parse. The decoding error's coding path names a
    /// CoreSimulator runtime, which must not read as CoreSimulator's failure: a restart wouldn't help.
    @Test func aListThatDoesNotParseIsNotFixedByRestarting() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        fake.stub(["xcrun", "simctl", "list", "-j"],
                  stdout: #"{"devicetypes": [], "runtimes": [], "devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [{"udid": 7}]}}"#)
        fake.stub(["pkill"]) { _ in ProcessOutput() }
        let report = await doctor(project).run(fix: true, checks: [CoreSimulatorCheck()], from: nil)
        let problem = try #require(report.problems.first)
        #expect(problem.message.hasPrefix("simctl couldn't list simulators: could not parse `simctl list -j` output: "))
        #expect(problem.message.contains("com.apple.CoreSimulator.SimRuntime.iOS-27-0"))
        #expect(problem.action == nil && problem.next != nil && !problem.fixed)
        #expect(pkillCalls == 0)
    }

    /// A `simctl list` that times out means the service is hung, so it isn't retried, and `--fix`
    /// restarts it.
    @Test func aListThatTimesOutIsFixedByRestartingAtOnce() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let listing = Fixture.string("simctl-list.json")
        let restarted = Counter()
        fake.stub(["xcrun", "simctl", "list", "-j"]) { inv in
            guard restarted.value > 0 else {
                throw XcdError.subprocess(inv, ProcessOutput(exitCode: 15), code: .timeout,
                                          message: "`xcrun simctl list` timed out after 120 seconds")
            }
            return ProcessOutput(stdout: listing)
        }
        let problem = try await restart(project, counting: restarted)
        #expect(problem.action == .restartCoreSimulator && problem.fixed)
        #expect(pkillCalls == 1)
        let lists = fake.calls.map(\.argv).prefix { $0.first != "pkill" }.filter { $0 == ["xcrun", "simctl", "list", "-j"] }
        #expect(lists.count == 1)                                               // no retries before the restart
    }

    /// Stderr that merely mentions a connection isn't CoreSimulator's broken connection.
    @Test func anUnrelatedConnectionErrorIsNotFixedByRestarting() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        fake.stub(["xcrun", "simctl", "list", "-j"], exitCode: 1,
                  stderr: "error: could not open a connection to the license agreement server")
        fake.stub(["pkill"]) { _ in ProcessOutput() }
        let report = await doctor(project).run(fix: true, checks: [CoreSimulatorCheck()], from: nil)
        #expect(report.problems.first?.action == nil)
        #expect(pkillCalls == 0)
        // A connection to the service that broke still counts.
        for stderr in ["CoreSimulatorService connection became invalid", "Connection interrupted", "The connection was invalidated"] {
            let failure = XcdError(.simulatorFailed, "`xcrun simctl list` failed (exit 1)",
                                   details: ["command: xcrun simctl list -j", "exit: 1", stderr])
            #expect(CoreSimulatorCheck.isCoreSimulatorFailure(failure), "\(stderr)")
        }
    }

    /// With nothing on stderr, the error ends at its exit code, without "exit: 1" detail noise.
    @Test func aListFailureWithoutStderrEndsAtItsExitCode() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        fake.stub(["xcrun", "simctl", "list", "-j"], exitCode: 1)
        let env = await doctor(project).environment(from: nil)
        #expect(env.catalog == nil)
        #expect(env.catalogError == "`xcrun simctl list` failed (exit 1)")
    }
}
