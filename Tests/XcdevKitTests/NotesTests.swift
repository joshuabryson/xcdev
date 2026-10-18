import Testing
import XcdevTestSupport
@testable import XcdevKit

private struct DataText: Reportable {
    var text: String { "/c" }
    var textIsData: Bool { true }
}

private struct FailedData: Reportable {
    var text: String { "/c" }
    var textIsData: Bool { true }
    var failure: XcdError? { XcdError(.usage, "no container", next: "launch the app first") }
}

private struct OwnNext: Reportable {
    var text: String { "app  state=not_running\nnext: start the app with `xcd run` or `xcd launch`" }
}

private struct Built: Reportable {
    let name: String
    var text: String { "build succeeded \(name)" }
    var envelopeWorktree: String? { "feat" }
}

private struct FailedBuild: Reportable {
    let name: String
    var text: String { "build failed \(name)" }
    var envelopeWorktree: String? { "feat" }
    var failure: XcdError? { XcdError(.buildFailed, "build failed with 1 error", next: "fix the errors and re-run `xcd build`") }
}

@Suite struct NotesTests {
    static let borrowed = "this branch has no .xcdev.yml, so xcd uses the main checkout's (/p/.xcdev.yml)"

    @Test func aFailedDataResultIsItsTextAloneAndItsNextGoesToStandardError() {
        #expect(Renderer.report(FailedData(), command: "sim container", format: .text, notes: ["x"]) == "/c")
        #expect(Renderer.standardErrorLines(for: FailedData(), format: .text, notes: ["x"]) == "note: x\nnext: launch the app first\n")
        #expect(Renderer.standardErrorLines(for: DataText(), format: .text, notes: ["x"]) == "note: x\n")
        #expect(Renderer.standardErrorLines(for: FailedData(), format: .json, notes: ["x"]) == "")
        #expect(Renderer.standardErrorLines(for: Built(name: "a"), format: .text, notes: ["x"]) == "")
    }

    @Test func aNoteIsKeptOnceInTheOrderAdded() {
        let notes = Notes()
        notes.add("b")
        notes.add("a")
        notes.add("b")
        #expect(notes.all == ["b", "a"])
    }

    @Test func textNotesFollowTheResultAndComeBeforeNext() {
        let out = Renderer.report(FailedBuild(name: "a"), command: "build", format: .text, notes: [Self.borrowed])
        #expect(out == """
        build failed a
        note: \(Self.borrowed)
        next: fix the errors and re-run `xcd build`
        """)
        #expect(Renderer.report(Built(name: "a"), command: "build", format: .text, notes: ["x"]) == "build succeeded a\nnote: x")
    }

    @Test func textNotesFollowAFailuresDetailsAndComeBeforeNext() {
        let error = XcdError(.hookFailed, "the pre-build hook failed (exit 1)", next: "fix the hook", details: ["log: /l"])
        #expect(Renderer.failure(error, command: "build", format: .text, notes: ["x"]) == """
        error[hook_failed]: the pre-build hook failed (exit 1)
          log: /l
        note: x
        next: fix the hook
        """)
    }

    @Test func theCommandsNotesAreTheDefault() {
        let notes = Notes()
        notes.add("x")
        let error = XcdError(.configMissing, "no .xcdev.yml", next: "n")
        Notes.$current.withValue(notes) {
            #expect(Renderer.report(Built(name: "a"), command: "build", format: .text) == "build succeeded a\nnote: x")
            #expect(Renderer.failure(error, command: "build", format: .text) == "error[config_missing]: no .xcdev.yml\nnote: x\nnext: n")
        }
        #expect(Renderer.report(Built(name: "a"), command: "build", format: .text) == "build succeeded a")
    }

    @Test func jsonCarriesNotesOnSuccessAndOnFailure() {
        let success = Renderer.report(Built(name: "a"), command: "build", format: .json, notes: ["x"])
        #expect(success == #"{"command":"build","data":{"name":"a"},"notes":["x"],"ok":true,"worktree":"feat"}"#)
        let failure = Renderer.failure(XcdError(.configMissing, "no .xcdev.yml", next: "n"), command: "build", format: .json,
                                       notes: ["x"])
        #expect(failure == #"{"command":"build","error":{"code":"config_missing","message":"no .xcdev.yml","next":"n"},"notes":["x"],"ok":false}"#)
    }

    @Test func aResultWhoseTextIsDataKeepsItAndItsNotesGoToStderr() {
        #expect(Renderer.report(DataText(), command: "c", format: .text, notes: ["x"]) == "/c")
        #expect(Renderer.report(DataText(), command: "c", format: .json, notes: ["x"]).contains(#""notes":["x"]"#))
        #expect(Renderer.noteLines(["x", "y"]) == "note: x\nnote: y\n")
        #expect(Renderer.noteLines([]) == "")
    }

    @Test func theResultsScriptsReadAreData() {
        let pasteboard = PasteboardReport(device: "d", udid: "u", text: "t", worktree: "w")
        let container = ContainerReport(device: "d", udid: "u", bundleId: "b", container: "data", path: "/p",
                                        groups: nil, worktree: "w")
        let context = ContextInfo(projectRoot: "/p", worktree: "w", worktreeName: "w", device: nil, udid: nil,
                                  runtime: nil, derivedData: "/d", appPath: nil, bundleId: nil, developerDir: nil,
                                  output: nil, mediaDir: nil)
        #expect(pasteboard.textIsData && container.textIsData && context.textIsData)
        #expect(!Built(name: "a").textIsData)
    }

    @Test func aResultsOwnNextStaysLastAfterTheNotes() {
        #expect(Renderer.report(OwnNext(), command: "c", format: .text, notes: ["x"]) == """
        app  state=not_running
        note: x
        next: start the app with `xcd run` or `xcd launch`
        """)
    }

    @Test func theWorktreeServiceSharesTheCommandsNotes() {
        let services = Services(runner: FakeProcessRunner(), globalPaths: GlobalPaths(base: "/h"),
                                currentDirectory: "/cwd", environment: [:])
        #expect(services.worktrees.notes === services.notes)
    }
}
