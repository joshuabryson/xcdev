import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"
private let swiftLint = ToolLocator(environment: ProcessInfo.processInfo.environment).locate("swiftlint", path: nil, worktreeRoot: "/")

/// `xcd lint` with the real git and the real SwiftLint, on a throwaway repository. No
/// simulator, no build. The project's lint config has what the scratch folder must carry over: an `included` and
/// an `excluded` list, a parent config, a nested config, and a custom rule that goes by path.
@Suite(.enabled(if: enabled && swiftLint != nil, "set XCD_INTEGRATION=1 to run (needs SwiftLint: brew install swiftlint)"), .serialized)
struct LintIntegrationTests {
    static let longLine = "let text = \"" + String(repeating: "a", count: 60) + "\""

    static let rootConfig = """
    parent_config: config/base.yml
    included:
      - Sources
    excluded:
      - Sources/Generated
    function_body_length:
      warning: 5
      error: 50
    custom_rules:
      no_print:
        name: "No print"
        regex: 'print\\('
        message: "Use the logger"
        severity: warning
        included: ".*/Sources/App/.*\\\\.swift"

    """

    /// `main` holds the files below. Branch `work` is checked out, with nothing changed yet.
    func project() throws -> TempProject {
        let project = try TempProject.make(config: "version: 1\nproject: Package.swift\nlint:\n  tool: swiftlint\n", name: "Lint App")
        try project.write(Self.rootConfig, to: ".swiftlint.yml")
        try project.write("line_length: 60\n", to: "config/base.yml")
        try project.write("disabled_rules:\n  - line_length\n", to: "Sources/App/Legacy/.swiftlint.yml")
        try project.write("func login() {\n    print(\"old\")\n    step()\n    step()\n    step()\n    step()\n}\n\nfunc step() {}\n",
                          to: "Sources/App/Login.swift")
        try project.write("func legacy() {}\n", to: "Sources/App/Legacy/Old.swift")
        try project.write("func untouched() {\n    print(\"untouched\")\n}\n", to: "Sources/App/Untouched.swift")
        try project.write("func generated() {}\n", to: "Sources/Generated/G.swift")
        try project.write("func tested() {}\n", to: "Tests/T.swift")
        try project.commit("Base")
        try project.git("checkout", "-q", "-b", "work")
        return project
    }

    /// The change: Login.swift gets a comment on top, one more line in `login()` (which makes it too long), and a
    /// second `print`. A new file has a line that is too long by the parent config. A file under the nested config
    /// gets the same long line, and a `print`. A generated file and a test file get a `print` each.
    func change(_ project: TempProject) throws {
        try project.write("// Signs the user in.\nfunc login() {\n    print(\"old\")\n    step()\n    step()\n    step()\n    step()\n"
                          + "    step()\n    print(\"new\")\n}\n\nfunc step() {}\n", to: "Sources/App/Login.swift")
        try project.write(Self.longLine + "\n", to: "Sources/App/New.swift")
        try project.write("func legacy() {\n    \(Self.longLine)\n    print(text)\n}\n", to: "Sources/App/Legacy/Old.swift")
        try project.write("func generated() { print(\"generated\") }\n", to: "Sources/Generated/G.swift")
        try project.write("func tested() { print(\"tested\") }\n\(Self.longLine)\n", to: "Tests/T.swift")
    }

    func services(_ project: TempProject) -> Services {
        Services(runner: SystemProcessRunner(), globalPaths: GlobalPaths(base: project.home), currentDirectory: project.root,
                 environment: ProcessInfo.processInfo.environment, interrupts: Interrupts())
    }

    /// Everything in the repository but git's own folder and xcd's state folder.
    func files(_ project: TempProject) throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: project.root)
            .filter { !$0.hasPrefix(".git/") && $0 != ".git" && !$0.hasPrefix(".xcdev/") && $0 != ".xcdev" }.sorted()
    }

    func scratchFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter { $0.hasPrefix("xcd-lint-") }
    }

    func summary(_ report: LintReport) -> [String] {
        report.findings.map { "\($0.file):\($0.line ?? 0) \($0.rule) \($0.severity.rawValue)" }
    }

    /// What the change introduced, as the default scope lists it.
    static let introduced = [
        "Sources/App/Legacy/Old.swift:3 no_print warning",              // the nested config turns line_length off there, not this
        "Sources/App/Login.swift:2 function_body_length warning",       // on `func login() {`, a line the change did not edit
        "Sources/App/Login.swift:9 no_print warning",
        "Sources/App/New.swift:1 line_length warning",                  // 60 is the parent config's limit
    ]

    func expectIntroduced(_ report: LintReport) {
        #expect(summary(report) == Self.introduced, "\(report.text)")
        #expect(report.older == 1, "\(report.text)")                         // print("old"), now one line further down
        #expect(report.files == 5 && report.base == "main" && report.failure == nil)
    }

    @Test func theDefaultScopeListsExactlyWhatTheChangeIntroduced() async throws {
        let project = try project()
        defer { project.remove() }
        try change(project)
        let before = try files(project)
        let scratch = scratchFolders()
        let svc = services(project)
        let report = try await svc.lint.lint(LintOptions(), in: try await svc.open(worktree: nil))

        expectIntroduced(report)
        #expect(report.notes.isEmpty, "\(report.notes)")
        #expect(try files(project) == before)                                // nothing new in the repository
        #expect(scratchFolders() == scratch)                                 // and the scratch folders are gone
        #expect(FileManager.default.fileExists(atPath: report.log ?? "/"))
    }

    @Test func filesListsTheOlderFindingsTooAndNothingFromOtherFiles() async throws {
        let project = try project()
        defer { project.remove() }
        try change(project)
        let svc = services(project)
        let report = try await svc.lint.lint(LintOptions(files: true), in: try await svc.open(worktree: nil))
        #expect(summary(report) == [
            "Sources/App/Legacy/Old.swift:3 no_print warning",
            "Sources/App/Login.swift:2 function_body_length warning",
            "Sources/App/Login.swift:3 no_print warning",
            "Sources/App/Login.swift:9 no_print warning",
            "Sources/App/New.swift:1 line_length warning",
        ], "\(report.text)")
        // Untouched.swift has a print too, and the excluded and not-included files changed: none of them is here.
        #expect(report.older == 0)
    }

    /// The worktree's state folder holds DerivedData and package checkouts: Swift files that are not the project's.
    @Test func allLintsTheProjectAndNothingInTheStateFolder() async throws {
        let project = try project()
        defer { project.remove() }
        try change(project)
        let svc = services(project)
        let ctx = try await svc.open(worktree: nil)                           // makes .xcdev/, which ignores itself
        try project.write("func dependency() { print(\"x\") }\n\(Self.longLine)\n", to: ".xcdev/SourcePackages/checkouts/Dep/Sources/App/D.swift")
        let report = try await svc.lint.lint(LintOptions(all: true), in: ctx)
        #expect(summary(report) == [
            "Sources/App/Legacy/Old.swift:3 no_print warning",
            "Sources/App/Login.swift:2 function_body_length warning",
            "Sources/App/Login.swift:3 no_print warning",
            "Sources/App/Login.swift:9 no_print warning",
            "Sources/App/New.swift:1 line_length warning",
            "Sources/App/Untouched.swift:2 no_print warning",
        ], "\(report.text)")
        #expect(report.files == 6 && report.base == nil)
    }

    @Test func strictMakesWarningsFailTheCommand() async throws {
        let project = try project()
        defer { project.remove() }
        try change(project)
        try project.write("version: 1\nproject: Package.swift\nlint:\n  tool: swiftlint\n  args: [\"--strict\"]\n", to: ".xcdev.yml")
        let svc = services(project)
        let report = try await svc.lint.lint(LintOptions(paths: ["Sources/App/New.swift"]), in: try await svc.open(worktree: nil))
        #expect(summary(report) == ["Sources/App/New.swift:1 line_length error"], "\(report.text)")
        #expect(report.failure?.code == .lintFailed)
    }

    /// SwiftLint does not stop for a config it cannot read: it warns and lints with its default rules. The warning
    /// is shown, so the findings are not taken for the project's.
    @Test func aConfigSwiftLintCannotReadIsShownAsANote() async throws {
        let project = try project()
        defer { project.remove() }
        try change(project)
        try project.write("included: [Sources\n", to: ".swiftlint.yml")
        let svc = services(project)
        let report = try await svc.lint.lint(LintOptions(files: true), in: try await svc.open(worktree: nil))
        #expect(report.notes.first?.hasPrefix("swiftlint: warning: Cannot parse YAML file") == true, "\(report.notes)")
        #expect(report.text.contains("\nlog: "))
    }

    /// A worktree's change is usually committed: the base version of a file is read at the fork point, not at `HEAD`.
    @Test func aCommittedChangeIsMeasuredFromWhereTheWorkLeftItsBase() async throws {
        let project = try project()
        defer { project.remove() }
        try change(project)
        try project.commit("Work")
        let svc = services(project)
        let report = try await svc.lint.lint(LintOptions(), in: try await svc.open(worktree: nil))
        expectIntroduced(report)
    }

    /// SwiftLint counts a CR and an LF each as a line end, so in a CRLF file source line N is its line 2N-1.
    @Test func aFileWithWindowsLineEndingsKeepsItsOldFindingsOld() async throws {
        let project = try project()
        defer { project.remove() }
        try project.git("checkout", "-q", "main")
        try project.write("func windows() {\r\n    print(\"one\")\r\n}\r\n", to: "Sources/App/Windows.swift")
        try project.commit("Windows file")
        try project.git("checkout", "-q", "-B", "work")
        try project.write("func windows() {\r\n    print(\"one\")\r\n    print(\"two\")\r\n}\r\n", to: "Sources/App/Windows.swift")
        let svc = services(project)
        let report = try await svc.lint.lint(LintOptions(), in: try await svc.open(worktree: nil))
        #expect(summary(report) == ["Sources/App/Windows.swift:5 no_print warning"], "\(report.text)")
        #expect(report.older == 2, "\(report.text)")                         // print("one") and trailing_newline
        #expect(report.files == 1)
    }
}
