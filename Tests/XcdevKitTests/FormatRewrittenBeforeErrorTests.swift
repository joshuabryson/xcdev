import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

extension FormatProject {
    /// The usual change, and D.swift as a third file in scope, with blanks at the end of its line.
    func changeThreeFiles() throws {
        try change()
        try project.write("let d = 1   \n", to: "Sources/App/D.swift")
    }

    /// The service with `formatters`, running `atOnce` of them at a time: with 1, the files go one after the other,
    /// in their order.
    func service(_ formatters: FakeFormatters, atOnce: Int) -> FormatService {
        var service = service(formatters)
        service.atOnce = atOnce
        return service
    }
}

/// An error that ends `xcd format` after files were rewritten says which ones: the result
/// that would have listed them is never printed. Git is real. A formatter "that cannot be started" is a runner that
/// throws what the real one throws when a launch fails, so nothing here waits on a clock.
@Suite struct FormatRewrittenBeforeErrorTests {
    static let heading = "reformatted before this error:"

    /// Has the runner fail to launch SwiftFormat for `path`, as the real one does for an executable that is gone.
    /// `then` runs just before it throws.
    func failLaunch(for path: String, in project: FormatProject, then: (@Sendable () -> Void)? = nil) {
        project.fake.stub(["swiftformat", "stdin", "--stdin-path", project.root + "/" + path]) { call in
            defer { then?() }
            throw XcdError(.subprocessFailed, "could not launch \(call.executable): No such file or directory", details: ["command: \(call.commandLine)"])
        }
    }

    /// The last lines of an error's details.
    func end(_ error: XcdError?, _ count: Int = 2) -> [String] { Array((error?.details ?? []).suffix(count)) }

    @Test func aFormatterThatCannotBeStartedForALaterFileNamesTheFilesAlreadyRewritten() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        try project.changeThreeFiles()
        let ctx = try await project.context()
        let formatters = FakeFormatters()
        let service = project.service(formatters, atOnce: 1)
        failLaunch(for: "Sources/App/C.swift", in: project)
        let error = await #expect(throws: XcdError.self) { _ = try await service.format(FormatOptions(), in: ctx) }

        #expect(error?.code == .subprocessFailed && error?.code.exitCode == 3)
        #expect(error?.message == "could not launch \(project.bin)/swiftformat: No such file or directory")
        #expect(error?.next == "see that \(project.bin)/swiftformat can be run, or set format.path in .xcdev.local.yml to one that can")
        #expect(error?.details.first?.hasPrefix("command: swiftformat stdin --stdin-path ") == true)
        #expect(end(error) == [Self.heading, "Sources/App/A.swift"])
        #expect(try project.read("Sources/App/A.swift") == FormatServiceTests.lineSeven)     // rewritten, as the error says
        #expect(try project.read("Sources/App/D.swift") == "let d = 1   \n")                 // no further file was started
        #expect(formatters.runs.map(\.file) == [project.root + "/Sources/App/A.swift"])
    }

    /// Two files at once. A.swift's formatter answers only after C.swift's could not be started: it is let finish,
    /// its file is written, and the error names it.
    @Test func aFormatterUnderWayWhenAnotherCannotBeStartedIsLetFinish() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        try project.change()
        let ctx = try await project.context()
        let service = project.service(FakeFormatters(), atOnce: 2)
        let failed = DispatchSemaphore(value: 0)
        failLaunch(for: "Sources/App/C.swift", in: project) { failed.signal() }
        project.fake.stub(["swiftformat", "stdin", "--stdin-path", project.root + "/Sources/App/A.swift"]) { _ in
            _ = failed.wait(timeout: .now() + 5)                                     // a guard against hanging, not what the test rests on
            return ProcessOutput(exitCode: 0, stdout: FormatServiceTests.lineSeven, stderr: "")
        }
        let error = await #expect(throws: XcdError.self) { _ = try await service.format(FormatOptions(), in: ctx) }
        #expect(error?.code == .subprocessFailed && end(error) == [Self.heading, "Sources/App/A.swift"])
        #expect(try project.read("Sources/App/A.swift") == FormatServiceTests.lineSeven)
    }

    /// A check rewrites nothing, and an error before any file was rewritten has nothing to name.
    @Test func aCheckAndAnErrorBeforeAnyFileWasRewrittenAddNothing() async throws {
        let project = try FormatProject()
        defer { project.project.remove() }
        try project.change()
        let changed = try project.read("Sources/App/A.swift")
        let ctx = try await project.context()
        let service = project.service(FakeFormatters(), atOnce: 1)
        failLaunch(for: "Sources/App/C.swift", in: project)
        let checked = await #expect(throws: XcdError.self) { _ = try await service.format(FormatOptions(check: true), in: ctx) }
        #expect(checked?.code == .subprocessFailed && checked?.details.count == 1 && checked?.next != nil)
        #expect(try project.read("Sources/App/A.swift") == changed)

        failLaunch(for: "Sources/App/A.swift", in: project)
        let first = await #expect(throws: XcdError.self) { _ = try await service.format(FormatOptions(), in: ctx) }
        #expect(first?.code == .subprocessFailed && first?.details.count == 1 && first?.details.contains(Self.heading) == false)
        #expect(try project.read("Sources/App/A.swift") == changed)
    }

    @Test func aFormatCommandWhoseLastStepIsNotFoundNamesTheFilesItRewrote() async throws {
        let run = FormatOwnCommandTests.strip + "; no-such-command-of-xcd"
        let project = try FormatProject(FormatOwnCommandTests.config(run: run, check: "no-such-command-of-xcd"))
        defer { project.project.remove() }
        try project.change()
        let ctx = try await project.context()
        let error = await #expect(throws: XcdError.self) { _ = try await project.service(FakeFormatters()).format(FormatOptions(), in: ctx) }

        #expect(error?.code == .subprocessFailed && error?.code.exitCode == 3)
        #expect(error?.message == "the project's format command could not be run (exit 127)")
        #expect(error?.next == "its command was not found; check format.run in .xcdev.yml (paths are relative to the worktree root)")
        #expect(error?.details.first == "command: \(run)")
        #expect(end(error) == [Self.heading, "Sources/App/A.swift"])
        #expect(try project.read("Sources/App/A.swift").contains("    let d = 40\n"))
        // A check command is trusted to rewrite nothing, so its error names no file.
        let checked = await #expect(throws: XcdError.self) { _ = try await project.service(FakeFormatters()).format(FormatOptions(check: true), in: ctx) }
        #expect(checked?.code == .subprocessFailed && checked?.details.contains(Self.heading) == false)
    }

    /// The runner stops a command at its deadline by throwing `timeout`. Here the shell is a stand-in that rewrites a
    /// file, and then the runner throws just that: no deadline is set, and nothing waits for one.
    @Test func aFormatCommandStoppedAtItsDeadlineNamesTheFilesItRewrote() async throws {
        let project = try FormatProject(FormatOwnCommandTests.config(run: "./format.sh \"$@\""))
        defer { project.project.remove() }
        try project.change()
        let ctx = try await project.context()
        let rewritten = URL(fileURLWithPath: project.root + "/Sources/App/C.swift")
        project.fake.stub(["sh", "-c"]) { call in
            try Data("struct C {}\n".utf8).write(to: rewritten)
            throw XcdError(.timeout, "`\(call.argv.prefix(3).joined(separator: " "))` timed out after \(call.timeout)")
        }
        let host = QualityHost(runner: RoutingRunner(fake: project.fake, realExecutables: ["git"]), locator: ToolLocator(environment: [:], extraFolders: []),
                               currentDirectory: project.root, interrupts: Interrupts())
        let error = await #expect(throws: XcdError.self) { _ = try await FormatService(host).format(FormatOptions(), in: ctx) }

        #expect(error?.code == .timeout && error?.code.exitCode == 3)
        #expect(error?.message == "the project's format command timed out after 10m00s")
        #expect(error?.next == "make format.run finish sooner, or name paths to give it fewer files")
        #expect(error?.details.first == "command: ./format.sh \"$@\"" && error?.details.count == 4)
        #expect(end(error) == [Self.heading, "Sources/App/C.swift"])
    }
}
