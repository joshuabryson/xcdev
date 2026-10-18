import Testing
@testable import XcdevKit

/// What doctor's failure says when it cannot tell which project it is in and CoreSimulator is not answering.
@Suite struct DoctorAskTests {
    @Test func gitsFailureIsFollowedByTheAskBeforeARestart() {
        let gitNext = "ask the user where the main checkout is now; until git can find this project, `xcd doctor --fix` repairs nothing"
        var located = DoctorProblem(check: "project", message: "this checkout is a git worktree, and its repository is gone", next: gitNext)
        located.scope = .project
        var mac = DoctorProblem(check: "coresimulator", message: "CoreSimulator didn't answer", action: .restartCoreSimulator,
                                fix: "restart the CoreSimulator service; every booted simulator on this Mac shuts down")
        mac.scope = .mac
        var report = DoctorReport(fixMode: true, checks: [.init(id: "project", problems: [located]),
                                                          .init(id: "coresimulator", problems: [mac])], disk: nil)
        report.located = false
        #expect(report.failure?.next == gitNext + "; ask the user before running `xcd doctor --restart-simulators`: it shuts down "
                    + "every booted simulator on this Mac, other agents' too")
    }
}
