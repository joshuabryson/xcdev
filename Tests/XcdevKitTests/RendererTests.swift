import Testing
@testable import XcdevKit

private struct Sample: Reportable {
    let name: String
    var text: String { "hello \(name)" }
    var envelopeWorktree: String? { "feat" }
}

private struct FailedSample: Reportable {
    let name: String
    var text: String { "build failed \(name)" }
    var envelopeWorktree: String? { "feat" }
    var failure: XcdError? {
        XcdError(.buildFailed, "build failed with 1 error", next: "fix the errors and re-run `xcd build`")
    }
}

@Suite struct RendererTests {
    @Test func textTaskFailureAppendsNext() {
        #expect(Renderer.report(FailedSample(name: "a"), command: "build", format: .text) == """
        build failed a
        next: fix the errors and re-run `xcd build`
        """)
    }

    @Test func jsonTaskFailureCarriesDataAndError() {
        let out = Renderer.report(FailedSample(name: "a"), command: "build", format: .json)
        #expect(out == #"{"command":"build","data":{"name":"a"},"error":{"code":"build_failed","message":"build failed with 1 error","next":"fix the errors and re-run `xcd build`"},"ok":false,"worktree":"feat"}"#)
    }

    @Test func taskFailureExitCodes() {
        #expect(ErrorCode.buildFailed.exitCode == 1)
        #expect(ErrorCode.testFailed.exitCode == 1)
        #expect(ErrorCode.appCrashed.exitCode == 1)
        #expect(ErrorCode.appNotBuilt.exitCode == 2)
        #expect(ErrorCode.xcodeRuntimeMismatch.exitCode == 3)
        #expect(ErrorCode.xcodeRuntimeMismatch.rawValue == "xcode_runtime_mismatch")
    }

    @Test func textSuccessIsPayloadText() {
        #expect(Renderer.report(Sample(name: "a"), command: "x", format: .text) == "hello a")
    }

    @Test func jsonSuccessIsSortedCompactEnvelope() {
        let out = Renderer.report(Sample(name: "a"), command: "wt create", format: .json)
        #expect(out == #"{"command":"wt create","data":{"name":"a"},"ok":true,"worktree":"feat"}"#)
    }

    @Test func textFailureShowsCodeDetailsAndNext() {
        let error = XcdError(.worktreeDirty, "worktree 'feat' has uncommitted changes",
                             next: "commit or stash them, or re-run `xcd wt remove feat --force`",
                             details: ["M Sources/App.swift"])
        let out = Renderer.failure(error, command: "wt remove", format: .text)
        #expect(out == """
        error[worktree_dirty]: worktree 'feat' has uncommitted changes
          M Sources/App.swift
        next: commit or stash them, or re-run `xcd wt remove feat --force`
        """)
    }

    @Test func jsonFailureOmitsEmptyDetails() {
        let out = Renderer.failure(XcdError(.configMissing, "no .xcdev.yml", next: "run `xcd init`"),
                                   command: "sim boot", worktree: nil, format: .json)
        #expect(out == #"{"command":"sim boot","error":{"code":"config_missing","message":"no .xcdev.yml","next":"run `xcd init`"},"ok":false}"#)
    }

    @Test func usageFailureAsJSON() {
        let message = """
        Error: Missing expected argument '<name>'
        Help:  <name>  Worktree name.
        Usage: xcd worktree create <name> [--json]

        """
        let out = Renderer.usageFailure(message: message, arguments: ["wt", "create", "--json"], environment: [:])
        #expect(out == #"{"command":"wt create","error":{"code":"usage","details":["Help:  <name>  Worktree name.","Usage: xcd worktree create <name> [--json]"],"message":"Missing expected argument '<name>'","next":"run `xcd help` or `xcd <command> --help`"},"ok":false}"#)
    }

    @Test func usageFailureAsTextOrEnvJSON() {
        let text = Renderer.usageFailure(message: "Error: Unknown option '--bogus'", arguments: ["sim", "boot", "--bogus"],
                                         environment: [:])
        #expect(text == """
        error[usage]: Unknown option '--bogus'
        next: run `xcd help` or `xcd <command> --help`
        """)
        let json = Renderer.usageFailure(message: "Error: Unknown option '--bogus'", arguments: ["sim", "boot", "--bogus"],
                                         environment: ["XCD_OUTPUT": "json"])
        #expect(json.hasPrefix(#"{"command":"sim boot","error":{"code":"usage","message":"Unknown option '--bogus'""#))
    }

    @Test func formatResolution() {
        #expect(OutputFormat.resolve(jsonFlag: true, environment: [:]) == .json)
        #expect(OutputFormat.resolve(jsonFlag: false, environment: ["XCD_OUTPUT": "JSON"]) == .json)
        #expect(OutputFormat.resolve(jsonFlag: false, environment: [:]) == .text)
    }

    @Test func exitCodesByCategory() {
        #expect(ErrorCode.configInvalid.exitCode == 2)
        #expect(ErrorCode.worktreeDirty.exitCode == 2)
        #expect(ErrorCode.runtimeMissing.exitCode == 3)
        #expect(ErrorCode.timeout.exitCode == 3)
        #expect(ErrorCode.appInUse.exitCode == 3)
    }
}

@Suite struct ErrorsReportTests {
    @Test func hookFailedIsATaskFailure() {
        #expect(ErrorCode.hookFailed.rawValue == "hook_failed")
        #expect(ErrorCode.hookFailed.exitCode == 1)
    }

    @Test func listsEveryCodeOnce() {
        let report = ErrorsReport()
        #expect(report.errors.map(\.code) == ErrorCode.allCases.map(\.rawValue))
        #expect(Set(report.errors.map(\.code)).count == report.errors.count)
        #expect(report.errors.allSatisfy { !$0.summary.isEmpty })
        #expect(report.text.contains("\nhook_failed             1  A hook from .xcdev.yml exited non-zero; the error names the hook and its log.\n"))
        #expect(report.text.contains("\napp_in_use              3  A Mac launch under isolation: shared found the same app running from another worktree, which would share its data; the error names that worktree. isolation: suffix gives each worktree its own copy.\n"))
        #expect(ErrorCode.permissionMissing.summary.contains("or `xcd doctor --grant-…` at the user's word"))
    }
}
