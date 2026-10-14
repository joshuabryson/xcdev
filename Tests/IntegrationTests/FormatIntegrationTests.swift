import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"
private let swiftFormat = ToolLocator(environment: ProcessInfo.processInfo.environment).locate("swiftformat", path: nil, worktreeRoot: "/")
/// Whether the selected Xcode has Apple's swift-format, asked the way xcd asks.
private let hasAppleSwiftFormat: Bool = {
    let xcrun = Process()
    xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    xcrun.arguments = ["--find", "swift-format"]
    xcrun.standardOutput = FileHandle.nullDevice
    xcrun.standardError = FileHandle.nullDevice
    guard (try? xcrun.run()) != nil else { return false }
    xcrun.waitUntilExit()
    return xcrun.terminationStatus == 0
}()

/// `xcd format` with the real git, SwiftFormat, and swift-format, on a throwaway repository. No simulator, no build.
/// The project has a config file for each formatter in its root (four spaces) and
/// one for each in a nested folder (two spaces), and a folder and a file whose names have a space and accents.
@Suite(.enabled(if: enabled && swiftFormat != nil && hasAppleSwiftFormat,
                "set XCD_INTEGRATION=1 to run (needs SwiftFormat: brew install swiftformat, and an Xcode with swift-format)"), .serialized)
struct FormatIntegrationTests {
    /// Lines 2 to 5, 8 and 9 are not as either formatter leaves them.
    static let login = """
    struct Login {
        let name:String
        let token:String
        func send( ) -> Bool {
            let ok=true; let done=false
            return ok
        }
        let count:Int
        var retries:Int = 0
    }

    """
    /// Login.swift after the change: lines 2, 5 and 9 are edited, and still not formatted.
    static let changed = login.replacingOccurrences(of: "let name:String", with: "let user:String")
        .replacingOccurrences(of: "let done=false", with: "let sent=false").replacingOccurrences(of: "var retries:Int = 0", with: "var retries:Int = 3")
    /// What each formatter makes of the three changed lines, with lines 3, 4 and 8 as they were. SwiftFormat is told
    /// to end statements with a line break, so its line 5 becomes two lines; swift-format keeps that line as one.
    static let formatted: [FormatterKind: String] = [
        .swiftFormat: changed.replacingOccurrences(of: "let user:String", with: "let user: String")
            .replacingOccurrences(of: "let ok=true; let sent=false", with: "let ok = true\n        let sent = false")
            .replacingOccurrences(of: "var retries:Int = 3", with: "var retries: Int = 3"),
        .appleSwiftFormat: changed.replacingOccurrences(of: "let user:String", with: "let user: String")
            .replacingOccurrences(of: "let ok=true; let sent=false", with: "let ok = true; let sent = false")
            .replacingOccurrences(of: "var retries:Int = 3", with: "var retries: Int = 3"),
    ]
    static let accented = "Sources/App/Été 1/Été.swift"

    /// `main` holds the files below. Branch `work` is checked out, with nothing changed yet.
    func project(_ kind: FormatterKind) throws -> TempProject {
        let project = try TempProject.make(config: "version: 1\nproject: Package.swift\nformat:\n  tool: \(kind.rawValue)\n", name: "Format App")
        try project.write("--indent 4\n--semicolons never\n", to: ".swiftformat")
        try project.write("{\"version\":1,\"indentation\":{\"spaces\":4},\"lineLength\":100}\n", to: ".swift-format")
        try project.write("--indent 2\n", to: "Sources/App/Nested/.swiftformat")
        try project.write("{\"version\":1,\"indentation\":{\"spaces\":2}}\n", to: "Sources/App/Nested/.swift-format")
        try project.write(Self.login, to: "Sources/App/Login.swift")
        try project.write(Self.login, to: "Sources/App/Untouched.swift")
        try project.write("struct Deep {\n  let a:Int\n  let b:Int\n}\n", to: "Sources/App/Nested/Deep.swift")
        try project.write("struct Ete {\n    let a:Int\n    let b:Int\n}\n", to: Self.accented)
        try project.commit("Base")
        try project.git("checkout", "-q", "-b", "work")
        return project
    }

    /// The change: three lines of Login.swift, one line each in the nested folder's file and the accented one, and a
    /// new file that indents with two spaces and has no newline at its end.
    func change(_ project: TempProject) throws {
        try project.write(Self.changed, to: "Sources/App/Login.swift")
        try project.write("struct Deep {\n  let a:Int\n  let c:Int\n}\n", to: "Sources/App/Nested/Deep.swift")
        try project.write("struct Ete {\n    let a:Int\n    let c:Int\n}\n", to: Self.accented)
        try project.write("struct New {\n  let n:Int\n}", to: "Sources/App/New.swift")
    }

    func services(_ project: TempProject) -> Services {
        Services(runner: SystemProcessRunner(), globalPaths: GlobalPaths(base: project.home), currentDirectory: project.root,
                 environment: ProcessInfo.processInfo.environment, interrupts: Interrupts())
    }

    func format(_ options: FormatOptions, _ project: TempProject) async throws -> FormatReport {
        let svc = services(project)
        return try await svc.format.format(options, in: try await svc.open(worktree: nil))
    }

    /// Every file in the repository but git's own folder and xcd's state folder, with its bytes.
    func files(_ project: TempProject) throws -> [String: Data] {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: project.root)
            .filter { !$0.hasPrefix(".git/") && $0 != ".git" && !$0.hasPrefix(".xcdev/") && $0 != ".xcdev" }
        return Dictionary(uniqueKeysWithValues: paths.compactMap { path in
            FileManager.default.contents(atPath: project.root + "/" + path).map { (path, $0) }
        })
    }

    func read(_ path: String, _ project: TempProject) throws -> String {
        try String(contentsOfFile: project.root + "/" + path, encoding: .utf8)
    }

    func scratchFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter { $0.hasPrefix("xcd-format-") }
    }

    func lines(_ report: FormatReport) -> [String] {
        report.changed.map { $0.file + " " + ($0.lines ?? []).map(\.text).joined(separator: ",") }
    }

    /// The first success criterion: only the lines the change touched are reformatted, and every other byte of every
    /// file stays as it was. Login.swift has three changed ranges, and SwiftFormat makes the middle one a line longer.
    @Test(arguments: FormatterKind.allCases)
    func onlyTheLinesTheChangeTouchedAreReformatted(_ kind: FormatterKind) async throws {
        let project = try project(kind)
        defer { project.remove() }
        try change(project)
        let before = try files(project)
        let scratch = scratchFolders()
        let report = try await format(FormatOptions(), project)

        #expect(report.failure == nil && report.failed.isEmpty && report.notes.isEmpty, "\(report.text)")
        #expect(report.tool == kind.rawValue && report.files == 4 && report.base == "main")
        #expect(try read("Sources/App/Login.swift", project) == Self.formatted[kind])
        #expect(try read("Sources/App/Nested/Deep.swift", project) == "struct Deep {\n  let a:Int\n  let c: Int\n}\n")     // the nested config's two spaces
        #expect(try read(Self.accented, project) == "struct Ete {\n    let a:Int\n    let c: Int\n}\n")
        #expect(try read("Sources/App/New.swift", project) == "struct New {\n    let n: Int\n}\n")                      // a new file, whole
        #expect(lines(report) == ["Sources/App/Login.swift " + (kind == .swiftFormat ? "2,5-6,10" : "2,5,9"), "Sources/App/Nested/Deep.swift 3",
                                  "Sources/App/New.swift 2-3", Self.accented + " 3"])
        let after = try files(project)
        #expect(after.keys.sorted() == before.keys.sorted())                         // nothing new in the repository
        #expect(after["Sources/App/Untouched.swift"] == before["Sources/App/Untouched.swift"])
        #expect(scratchFolders() == scratch)                                         // and no scratch folder is left
        let again = try await format(FormatOptions(check: true), project)
        #expect(again.failure == nil && again.changed.isEmpty, "\(again.text)")      // what was written is as the formatter wants it
    }

    @Test(arguments: FormatterKind.allCases)
    func aCheckWritesNothingAndFailsWhenSomethingWouldChange(_ kind: FormatterKind) async throws {
        let project = try project(kind)
        defer { project.remove() }
        try change(project)
        let before = try files(project)
        let report = try await format(FormatOptions(check: true), project)
        #expect(try files(project) == before)
        #expect(report.failure?.code == .formatFailed && report.failure?.code.exitCode == 1)
        #expect(lines(report) == ["Sources/App/Login.swift 2,5,9", "Sources/App/Nested/Deep.swift 3", "Sources/App/New.swift 2-3", Self.accented + " 3"])
        #expect(report.text.hasPrefix("format: 4 files need formatting  tool=\(kind.rawValue)  files=4  base=main  "))
    }

    /// `--files` reformats the changed files whole, and leaves a file the change did not touch. `--all` reformats that
    /// one too, and nothing under `.xcdev/`.
    @Test(arguments: FormatterKind.allCases)
    func filesAndAllWidenTheScope(_ kind: FormatterKind) async throws {
        let project = try project(kind)
        defer { project.remove() }
        try change(project)
        let files = try await format(FormatOptions(files: true), project)
        #expect(files.failure == nil && files.changed.count == 4)
        let login = try read("Sources/App/Login.swift", project)
        #expect(login.contains("    let token: String\n") && login.contains("    func send() -> Bool {\n") && login.contains("    let count: Int\n"))
        #expect(try read("Sources/App/Untouched.swift", project) == Self.login)

        try project.write("struct Kept {\n  let k:Int\n}\n", to: ".xcdev/SourcePackages/checkouts/Dep/Sources/Kept.swift")
        let all = try await format(FormatOptions(all: true), project)
        #expect(all.failure == nil && all.files == 5 && all.base == nil)
        #expect(all.changed.map(\.file) == ["Sources/App/Untouched.swift"], "\(all.text)")       // the others were formatted just now
        #expect(try read(".xcdev/SourcePackages/checkouts/Dep/Sources/Kept.swift", project) == "struct Kept {\n  let k:Int\n}\n")
    }

    /// A file with an unresolved conflict counts as changed and neither formatter can read it. Each says so in its
    /// own words: swift-format names the file by its full path, and SwiftFormat names no file.
    @Test(arguments: FormatterKind.allCases)
    func aFileTheFormatterCannotReadIsListedInTheFormattersOwnWords(_ kind: FormatterKind) async throws {
        let project = try project(kind)
        defer { project.remove() }
        try change(project)
        let conflicted = "struct Conflicted {\n<<<<<<< HEAD\n    let a:Int\n=======\n    let b:Int\n>>>>>>> main\n}\n"
        try project.write(conflicted, to: "Sources/App/Conflicted.swift")
        let report = try await format(FormatOptions(), project)
        #expect(report.failure?.code == .formatFailed && report.failed.map(\.file) == ["Sources/App/Conflicted.swift"])
        #expect(report.failed.first?.message == (kind == .swiftFormat
            ? "Sources/App/Conflicted.swift: error: Found conflict marker <<<<<<< at 2:1."
            : "Sources/App/Conflicted.swift:2:1: error: source control conflict marker in source file"))
        #expect(try read("Sources/App/Conflicted.swift", project) == conflicted)
        #expect(report.changed.count == 4)                                           // the other files were still formatted
        #expect(try read("Sources/App/Login.swift", project) == Self.formatted[kind])
    }

    /// swift-format exits 0 and prints nothing for a file its `.swift-format-ignore` names. xcd leaves the file as
    /// it is; written back, that answer would empty it.
    @Test func aFileApplesIgnoreFileNamesIsLeftAsItIs() async throws {
        let project = try project(.appleSwiftFormat)
        defer { project.remove() }
        try change(project)
        try project.write("Sources/App/New.swift\n", to: ".swift-format-ignore")
        let report = try await format(FormatOptions(files: true), project)
        #expect(report.failure == nil, "\(report.text)")
        #expect(try read("Sources/App/New.swift", project) == "struct New {\n  let n:Int\n}")
        #expect(!report.changed.contains { $0.file == "Sources/App/New.swift" } && report.changed.count == 3)
    }

    /// Given lines of a file with CRLF endings, swift-format takes the indentation off the first of them and
    /// SwiftFormat takes the line ending off the line above. xcd hands neither such lines: the file is listed, and
    /// `--files` formats it whole.
    @Test(arguments: FormatterKind.allCases)
    func aFileWithWindowsLineEndingsIsFormattedWholeOrNotAtAll(_ kind: FormatterKind) async throws {
        let project = try project(kind)
        defer { project.remove() }
        let windows = Self.login.replacingOccurrences(of: "\n", with: "\r\n")
        try project.write(windows, to: "Sources/App/Windows.swift")
        try project.commit("A file with Windows line endings")
        try project.git("branch", "-f", "main", "HEAD")
        let edited = windows.replacingOccurrences(of: "let count:Int", with: "let total:Int")
        try project.write(edited, to: "Sources/App/Windows.swift")

        let byLines = try await format(FormatOptions(), project)
        #expect(byLines.failure?.code == .formatFailed && byLines.failed.map(\.file) == ["Sources/App/Windows.swift"])
        #expect(byLines.failed.first?.message.contains("has Windows line endings (CRLF)") == true)
        #expect(try read("Sources/App/Windows.swift", project) == edited)

        let whole = try await format(FormatOptions(files: true), project)
        #expect(whole.failure == nil && whole.changed.map(\.file) == ["Sources/App/Windows.swift"], "\(whole.text)")
        let formatted = try read("Sources/App/Windows.swift", project)
        #expect(formatted.contains("    let total: Int") && formatted.contains("    let token: String"))
    }
}

/// Edges found with the real tools (each has a unit test with stand-in formatters too).
extension FormatIntegrationTests {
    /// Puts `contents` at `path` in `main` (and on `work`), then checks `work` out with nothing changed.
    func commitToMain(_ contents: Data, at path: String, _ project: TempProject) throws {
        try write(contents, at: path, project)
        try project.commit("Add \(path)")
        try project.git("branch", "-f", "main", "HEAD")
    }

    func write(_ contents: Data, at path: String, _ project: TempProject) throws {
        try contents.write(to: URL(fileURLWithPath: project.root + "/" + path))
    }

    func bytes(_ path: String, _ project: TempProject) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: project.root + "/" + path))
    }

    /// SwiftFormat, given a range that reaches a last line with no newline, leaves out the text's last token
    /// (`let c =3`). xcd hands it a newline and takes it off again.
    @Test(arguments: FormatterKind.allCases)
    func aChangedLastLineWithNoNewlineIsFormattedAndStaysWithoutOne(_ kind: FormatterKind) async throws {
        let project = try project(kind)
        defer { project.remove() }
        let path = "Sources/App/Tail.swift"
        try commitToMain(Data("let a = 1\nlet   b = 2\nlet   c=3".utf8), at: path, project)
        try write(Data("let a = 1\nlet   b = 2\nlet   d=3".utf8), at: path, project)
        let report = try await format(FormatOptions(), project)
        #expect(report.failure == nil && report.failed.isEmpty, "\(report.text)")
        #expect(try bytes(path, project) == Data("let a = 1\nlet   b = 2\nlet d = 3".utf8))
        #expect(lines(report) == [path + " 3"])
    }

    /// SwiftFormat, given a range that starts on `else {`, joins it to the `}` on the line above, outside its range.
    /// xcd takes the join: the line above keeps what it held, the range higher up is still formatted on its own line,
    /// and a line the change did not touch stays unformatted.
    @Test func aChangeThatStartsOnElseIsJoinedToTheBraceAboveBySwiftFormat() async throws {
        let project = try project(.swiftFormat)
        defer { project.remove() }
        let path = "Sources/App/Branch.swift"
        let base = "func f(a: Bool) {\n    let x = 1\n    if a {\n        g()\n    }\n}\n\nfunc g() {}\nfunc h() {}\nfunc k(){}\n"
        try commitToMain(Data(base.utf8), at: path, project)
        let edited = base.replacingOccurrences(of: "let x = 1", with: "let y=1")
            .replacingOccurrences(of: "    }\n}\n", with: "    }\n    else {\n        h( )\n    }\n}\n")
        try write(Data(edited.utf8), at: path, project)
        let report = try await format(FormatOptions(), project)
        #expect(report.failure == nil && report.failed.isEmpty, "\(report.text)")
        #expect(try read(path, project) == "func f(a: Bool) {\n    let y = 1\n    if a {\n        g()\n    } else {\n        h()\n    }\n}\n\n"
            + "func g() {}\nfunc h() {}\nfunc k(){}\n")
        #expect(lines(report) == [path + " 2,5-6"])
    }

    /// SwiftFormat, given a range that starts on a comma under a line that ends in a comment, puts the comma inside
    /// the comment, and the call no longer compiles. xcd refuses the file; `--files`
    /// formats it whole, which SwiftFormat gets right.
    @Test func aLeadingCommaUnderACommentIsRefusedBySwiftFormatAndFormattedWithFiles() async throws {
        let project = try project(.swiftFormat)
        defer { project.remove() }
        let path = "Sources/App/Call.swift"
        try commitToMain(Data("let v = f(\n    a: 1 // one\n)\n".utf8), at: path, project)
        let edited = "let v = f(\n    a: 1 // one\n    , b: 2\n)\n"
        try write(Data(edited.utf8), at: path, project)
        let report = try await format(FormatOptions(), project)
        #expect(report.failure?.code == .formatFailed && report.failed.map(\.file) == [path] && report.changed.isEmpty, "\(report.text)")
        #expect(report.failed.first?.message.contains("swiftformat changed a line above line 3") == true)
        #expect(report.failed.first?.message.contains("xcd format --files") == true)
        #expect(try bytes(path, project) == Data(edited.utf8))

        let whole = try await format(FormatOptions(files: true), project)
        #expect(whole.failure == nil, "\(whole.text)")
        #expect(try read(path, project) == "let v = f(\n    a: 1, // one\n    b: 2\n)\n")
    }

    /// A `format.path` that names a script which prints a line of its own and then runs the real swift-format. The
    /// answer for a file's changed lines has that line in front of the file's first line: xcd writes none of it.
    @Test func aFormatPathScriptThatPrintsALineOfItsOwnChangesNoFileHandedOverByLines() async throws {
        let project = try project(.appleSwiftFormat)
        defer { project.remove() }
        try project.write("#!/bin/sh\necho formatting\nexec xcrun swift-format \"$@\"\n", to: "tools/chatty-format")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.root + "/tools/chatty-format")
        try project.write("version: 1\nproject: Package.swift\nformat:\n  tool: swift-format\n  path: tools/chatty-format\n", to: ".xcdev.yml")
        try project.write(Self.changed, to: "Sources/App/Login.swift")
        let report = try await format(FormatOptions(), project)
        #expect(report.failure?.code == .formatFailed && report.changed.isEmpty, "\(report.text)")
        #expect(report.failed.map(\.message) == ["Sources/App/Login.swift: the formatter changed lines other than lines 2, 5, 9, "
            + "which it was given, so the file was left as it was"])
        #expect(try read("Sources/App/Login.swift", project) == Self.changed)
    }

    /// Apple's swift-format prints a file without its byte order mark, and a `String` drops it: xcd keeps it.
    @Test(arguments: FormatterKind.allCases)
    func aFileThatStartsWithAByteOrderMarkKeepsItAndIsFormattedOnItsChangedLine(_ kind: FormatterKind) async throws {
        let project = try project(kind)
        defer { project.remove() }
        let path = "Sources/App/Marked.swift"
        let mark = Data([0xEF, 0xBB, 0xBF])
        let body = "struct Marked {\n    let a: Int\n    let b:Int\n    let c: Int\n}\n"
        try commitToMain(mark + Data(body.utf8), at: path, project)
        try write(mark + Data(body.replacingOccurrences(of: "let b:Int", with: "let d:Int").utf8), at: path, project)
        let report = try await format(FormatOptions(), project)
        #expect(report.failure == nil && report.failed.isEmpty, "\(report.text)")
        #expect(try bytes(path, project) == mark + Data(body.replacingOccurrences(of: "let b:Int", with: "let d: Int").utf8))
        #expect(lines(report) == [path + " 3"])
    }
}
