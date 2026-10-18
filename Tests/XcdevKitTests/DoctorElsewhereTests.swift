import Foundation
import Testing
@testable import XcdevKit

/// Another project's problems are listed apart and never fail this project's doctor.
@Suite struct DoctorElsewhereTests {
    func scoped(_ problem: DoctorProblem, _ scope: DoctorProblem.Scope) -> DoctorProblem {
        var problem = problem
        problem.scope = scope
        return problem
    }

    var own: DoctorProblem {
        scoped(DoctorProblem(check: "orphaned-clones", message: "own", action: .deleteSimulator, fix: "shut it down and delete it"), .project)
    }

    var nearby: DoctorProblem {
        scoped(DoctorProblem(check: "orphaned-clones", message: "nearby", action: .deleteSimulator, fix: "shut it down and delete it",
                             next: "ask the user before running `xcd doctor --fix` in /p/Nearby"), .otherProject)
    }

    @Test func aRunWithOnlyAnotherProjectsProblemsSucceedsAndListsThem() throws {
        let report = DoctorReport(fixMode: false, checks: [.init(id: "orphaned-clones", problems: [nearby])], disk: nil)
        #expect(report.failure == nil)
        #expect(report.text == """
            doctor: no problems here, 1 elsewhere
            ok       orphaned-clones
            elsewhere (not this project's to fix; ask the user):
            problem  orphaned-clones  nearby  next: ask the user before running `xcd doctor --fix` in /p/Nearby
            """)
        let json = Renderer.report(report, command: "doctor", format: .json)
        #expect(json.contains(#""elsewhere":true"#) && json.contains(#""ok":true"#))
    }

    @Test func aFixRunCountsWhatItFixedHereAndWhatIsElsewhere() {
        var fixed = own
        fixed.fixed = true
        let report = DoctorReport(fixMode: true, checks: [.init(id: "orphaned-clones", problems: [fixed, nearby])], disk: nil)
        #expect(report.text.hasPrefix("doctor: 1 problem, 1 fixed, 1 elsewhere\nfixed    orphaned-clones  own\nelsewhere"))
        #expect(report.failure == nil)
    }

    @Test func theFailuresNextNeverNamesAnotherProjectsFolder() {
        let report = DoctorReport(fixMode: true, checks: [.init(id: "orphaned-clones", problems: [nearby, own])], disk: nil)
        #expect(report.failure?.message == "1 problem remain")
        #expect(report.failure?.next == "read the problems above; `xcd doctor` checks again")
    }

    /// When git cannot say which project doctor runs in, it cannot tell another project's problem from this one's, so
    /// none is listed apart and every problem fails the run.
    @Test func whenDoctorCannotTellWhichProjectItIsInNothingIsElsewhere() {
        let mine = scoped(DoctorProblem(check: ProjectLocationCheck().id, message: "main is missing", action: nil,
                                        next: "check out main"), .project)
        let report = DoctorReport(fixMode: false, checks: [.init(id: "orphaned-clones", problems: [nearby]),
                                                           .init(id: ProjectLocationCheck().id, problems: [mine])],
                                  disk: nil, located: false)
        #expect(!report.text.contains("elsewhere (not this project's to fix; ask the user):"))
        #expect(report.text.hasPrefix("doctor: 2 problems\n"))
        #expect(report.elsewhere.isEmpty)
        #expect(report.failure != nil)
    }

    @Test func elsewhereFollowsTheScope() {
        var problem = nearby
        #expect(problem.elsewhere == true)
        problem.scope = .goneProject
        #expect(problem.elsewhere == nil)
        #expect(own.elsewhere == nil)
    }
}
