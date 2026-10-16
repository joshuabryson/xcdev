import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The warnings `xcd build`, `xcd run`, and `xcd test` show, from one build to the next.
/// git is real; xcodebuild is `FakeXcodebuild`, whose log names the files a build compiled.
@Suite struct BuildWarningsTests {
    let worktree = FakeWorktree(prefix: "xcd warnings")
    var fake: FakeProcessRunner { worktree.runner }
    let xcodebuild: FakeXcodebuild

    init() { xcodebuild = FakeXcodebuild(runner: worktree.runner) }

    /// A git repository whose `main` holds Login, Session, and Other, on a branch `work` that changed Login and Session.
    func context() throws -> WorktreeContext {
        let ctx = try worktree.context(BuildServiceTests.config, container: "App.xcodeproj")
        for name in ["Login", "Session", "Other"] { try write("struct \(name) {}\n", to: name) }
        for args in [["init", "-q", "-b", "main"], ["add", "-A"], ["-c", "user.name=xcd", "-c", "user.email=xcd@example.com", "commit", "-q", "-m", "Base"],
                     ["checkout", "-q", "-b", "work"]] {
            try TempProject.git(args, in: worktree.root)
        }
        try write("struct Login { let token = 1 }\n", to: "Login")
        try write("struct Session { let old = 1 }\n", to: "Session")
        xcodebuild.onBuildSettings(Fixture.string("build-settings.json"))
        return ctx
    }

    func write(_ text: String, to name: String) throws {
        try FileManager.default.createDirectory(atPath: worktree.root + "/Sources/App", withIntermediateDirectories: true)
        try text.write(toFile: path(name), atomically: false, encoding: .utf8)
    }

    func path(_ name: String) -> String { worktree.root + "/Sources/App/\(name).swift" }

    /// What the fake xcodebuild reports next: a log that compiled `compiling`, and `warnings` as (file, line, message).
    func next(compiling: [String], warnings: [(String, Int)], failed: Bool = false) {
        let lines = compiling.map { "SwiftCompile normal arm64 \(path($0).replacingOccurrences(of: " ", with: "\\ ")) (in target 'App' from project 'App')\n" }
        let issues = warnings.map { name, line in
            #"{"message":"warning in \#(name)","sourceURL":"\#(URL(fileURLWithPath: path(name)).absoluteString)#StartingLineNumber=\#(line - 1)&StartingColumnNumber=4"}"#
        }
        let errors = failed ? #"[{"message":"cannot find 'x' in scope"}]"# : "[]"
        xcodebuild.onRun(.init(exitCode: failed ? 65 : 0, log: lines.joined() + "** BUILD DONE **\n",
                               buildResults: #"{"status":"\#(failed ? "failed" : "succeeded")","errors":\#(errors),"warnings":[\#(issues.joined(separator: ","))]}"#))
    }

    func build(_ ctx: inout WorktreeContext, all: Bool = false) async throws -> BuildReport {
        try await BuildService(runner: RoutingRunner(fake: fake), provisioner: worktree.provisioner, now: { Date(timeIntervalSince1970: 1_790_040_000) })
            .build(BuildOptions(device: "mac", showWarnings: all), in: &ctx)
    }

    /// The line of the warning in `name`, as a result prints it: this build's at the path xcodebuild gave.
    func line(_ name: String, _ number: Int, earlier: Bool = false) -> String {
        Diagnostic(.warning, "warning in \(name)", file: earlier ? Disk.realPath(path(name)) : path(name), line: number, column: 5).text
    }

    @Test func aBuildThatCompilesNothingStillListsTheWarningsOfTheFilesYouChanged() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        next(compiling: ["Login", "Session", "Other"], warnings: [("Login", 42), ("Other", 3)])
        let first = try await build(&ctx)
        #expect(first.warningLines == [line("Login", 42), "1 warning in the files you changed, 1 in other files (xcd build --warnings)"])
        #expect(first.notes.first == WarningKeeper.firstRecord && first.warningCount == 2)

        next(compiling: [], warnings: [])
        let second = try await build(&ctx)
        #expect(second.warningLines == ["from earlier builds:", line("Login", 42, earlier: true),
                                        "1 warning in the files you changed (1 from an earlier build), 1 in other files (xcd build --warnings)"])
        #expect(second.warningCount == 2 && !second.notes.contains(WarningKeeper.firstRecord))
        let json = String(decoding: try JSONCoding.encoder(pretty: false).encode(second), as: UTF8.self)
        #expect(json.contains(#""changedFileWarnings":[{"#) && json.contains(#""earlier":true"#) && json.contains(#""warningCount":2"#))

        try write("struct Login { let token = 2 }\n", to: "Login")                  // the warning is fixed
        next(compiling: ["Login"], warnings: [])
        let fixed = try await build(&ctx)
        #expect(fixed.warningLines == ["1 warning in other files (xcd build --warnings)"] && fixed.changedFileWarnings == [])
    }

    /// The record holds a file's warnings only while the file is as it was then.
    @Test func aChangedFileThisBuildDidNotCompileIsNamed() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        next(compiling: ["Login", "Session", "Other"], warnings: [("Session", 1)])
        _ = try await build(&ctx)
        try write("struct Session { let newer = 1 }\n", to: "Session")
        next(compiling: [], warnings: [], failed: true)
        let failed = try await build(&ctx)
        #expect(failed.unknownChangedFiles == ["Sources/App/Session.swift"] && failed.warningCount == 0)
        #expect(failed.text.contains("\n1 error, 0 warnings\nwarnings not known for 1 changed file, which this build did not compile: "
                                         + "Sources/App/Session.swift\n"))
    }

    @Test func withWarningsEveryWarningXcdKnowsIsListed() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        next(compiling: ["Login", "Session", "Other"], warnings: [("Login", 42), ("Other", 3)])
        _ = try await build(&ctx)
        next(compiling: ["Other"], warnings: [("Other", 3)])
        let all = try await build(&ctx, all: true)
        #expect(all.warningLines == [line("Other", 3), "from earlier builds:", line("Login", 42, earlier: true),
                                     "1 warning in the files you changed (1 from an earlier build), 1 in other files"])
        #expect(all.warnings?.map { $0.earlier == true } == [false, true])
    }

    /// A result bundle that cannot be read says nothing about which warnings are gone.
    @Test func resultsThatCannotBeReadLeaveTheRecordAsItWas() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        next(compiling: ["Login", "Session", "Other"], warnings: [("Login", 42)])
        _ = try await build(&ctx)
        let record = WarningRecord.file(scheme: "App", device: "mac", configuration: nil, in: ctx.paths)
        let before = try Data(contentsOf: URL(fileURLWithPath: record))
        xcodebuild.onRun(.init(log: "SwiftCompile normal arm64 \(path("Login").replacingOccurrences(of: " ", with: "\\ ")) (in target 'App' from project 'App')\n"))
        let unread = try await build(&ctx)
        #expect(try Data(contentsOf: URL(fileURLWithPath: record)) == before)
        #expect(unread.notes.first == WarningKeeper.unreadable && unread.warningLines.isEmpty)
    }

    /// When the files the change touched cannot be worked out, the build itself is still the result.
    @Test func withoutABaseTheCountIsNotSplit() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try TempProject.git(["branch", "-m", "main", "trunk"], in: worktree.root)
        next(compiling: ["Login", "Session", "Other"], warnings: [("Login", 42), ("Other", 3)])
        let report = try await build(&ctx)
        #expect(report.succeeded && report.changedFileWarnings == nil && report.warningLines == ["2 warnings (xcd build --warnings)"])
        #expect(report.notes.contains("the warnings of the files you changed are not listed: no base to measure the change against: "
                                          + "this repository has no main or master branch, and origin/HEAD is not set"))
    }

    /// git failing is not the build's failure: the build is still the result.
    @Test func aCheckoutGitCannotReadStillBuildsAndSaysWhy() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        try "garbage\n".write(toFile: worktree.root + "/.git/HEAD", atomically: true, encoding: .utf8)
        next(compiling: ["Login"], warnings: [("Login", 42)])
        let report = try await build(&ctx)
        #expect(report.succeeded && report.failure == nil && report.warningLines == ["1 warning (xcd build --warnings)"])
        #expect(report.notes.contains("the warnings of the files you changed are not listed: "
                                          + "git failed: not a git repository (or any of the parent directories): .git"))
    }

    @Test func aTestRunShowsThemAndHasWarningsToo() async throws {
        defer { worktree.remove() }
        var ctx = try context()
        next(compiling: ["Login", "Other"], warnings: [("Login", 42), ("Other", 3)])
        let builds = BuildService(runner: RoutingRunner(fake: fake), provisioner: worktree.provisioner, now: { Date(timeIntervalSince1970: 1_790_040_000) })
        let tested = try await TestService(builds: builds).test(TestOptions(device: "mac"), in: &ctx)
        #expect(tested.text.contains("\n\(line("Login", 42))\n1 warning in the files you changed, 1 in other files (xcd test --warnings)\n"))
        next(compiling: [], warnings: [])
        let all = try await TestService(builds: builds).test(TestOptions(device: "mac", showWarnings: true), in: &ctx)
        #expect(all.warnings?.count == 2 && all.warningCount == 2)
    }

    @Test func runShowsTheBuildsWarningsUnderItsBuildLine() {
        var build = BuildReport(succeeded: true, scheme: "App", target: "mac", targetSummary: "mac", seconds: 1, errors: [], warningCount: 3,
                                warnings: nil, product: nil, log: "/w/b.log", resultBundle: nil, logTail: nil, worktree: "feat")
        build.changedFileWarnings = [Diagnostic.warning("/w/Login.swift", 42, "unused")]
        let run = RunReport(status: .running, build: build, target: "mac", targetSummary: "mac", bundleId: "dev.x.App", pid: 7,
                            appLog: nil, crashWindow: 2, exitedAfter: nil, crash: nil, appOutput: nil, note: nil, worktree: "feat")
        #expect(run.text.components(separatedBy: "\n").prefix(3) == [
            "build succeeded  scheme=App device=mac  1.0s", "/w/Login.swift:42:5: warning: unused",
            "1 warning in the files you changed, 2 in other files (xcd build --warnings)"])
    }
}
