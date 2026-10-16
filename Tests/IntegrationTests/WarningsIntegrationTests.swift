import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

private let enabled = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"

/// The warnings of the files a change touched, from one real xcodebuild run to the next. A Swift package built for the
/// Mac, so no simulator is involved.
@Suite(.enabled(if: enabled, "set XCD_INTEGRATION=1 to run (needs Xcode)"), .serialized)
struct WarningsIntegrationTests {
    static let package = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Warned",
            platforms: [.macOS(.v15)],
            targets: [
                .target(name: "Lib"),
                .testTarget(name: "LibTests", dependencies: ["Lib"]),
            ]
        )

        """

    /// A package whose `main` holds Login, Session, and Other, Other with an unused value. On branch `work`, Login
    /// has one too.
    func project() throws -> TempProject {
        let project = try TempProject.make(config: "version: 1\nproject: Package.swift\n", name: "Warned Package \(UUID().uuidString.prefix(6))")
        try project.write(Self.package, to: "Package.swift")
        try project.write("public func login() -> Int { 1 }\n", to: "Sources/Lib/Login.swift")
        try project.write("public func session() -> Int { 2 }\n", to: "Sources/Lib/Session.swift")
        try project.write("public func other() -> Int {\n    let spare = 3\n    return 3\n}\n", to: "Sources/Lib/Other.swift")
        try project.write("import Testing\n@testable import Lib\n\n@Test func works() { #expect(login() == 1) }\n", to: "Tests/LibTests/LibTests.swift")
        try project.commit("Base")
        try project.git("checkout", "-q", "-b", "work")
        try project.write("public func login() -> Int {\n    let token = 1\n    return 1\n}\n", to: "Sources/Lib/Login.swift")
        return project
    }

    func messages(_ warnings: [Diagnostic]?) -> [String] {
        (warnings ?? []).map { "\(($0.file as NSString?)?.lastPathComponent ?? "-"):\($0.line ?? 0)\($0.earlier == true ? " earlier" : "")" }
    }

    @Test func aWarningLastsUntilItsFileIsCompiledWithoutIt() async throws {
        let project = try project()
        defer { project.remove() }
        let svc = services(project)
        var ctx = try await svc.open(worktree: nil)

        let first = try await svc.builds.build(BuildOptions(), in: &ctx)
        #expect(first.succeeded && messages(first.changedFileWarnings) == ["Login.swift:2"], "\(first.text)")
        #expect(first.warningCount == 2 && first.notes.contains(WarningKeeper.firstRecord), "\(first.text)")

        // Nothing changed: xcodebuild compiles nothing and reports no warning.
        let second = try await svc.builds.build(BuildOptions(), in: &ctx)
        #expect(messages(second.changedFileWarnings) == ["Login.swift:2 earlier"] && second.warningCount == 2, "\(second.text)")
        #expect(second.text.contains("1 warning in the files you changed (1 from an earlier build), 1 in other files (xcd build --warnings)"))

        // Another file changed: Login keeps its warning, whether or not this build compiled it again.
        try project.write("public func session() -> Int { 4 }\n", to: "Sources/Lib/Session.swift")
        let third = try await svc.builds.build(BuildOptions(), in: &ctx)
        #expect(messages(third.changedFileWarnings).map { $0.replacingOccurrences(of: " earlier", with: "") } == ["Login.swift:2"], "\(third.text)")

        // The warning is fixed: the next build compiles Login and it is gone.
        try project.write("public func login() -> Int { return 1 }\n", to: "Sources/Lib/Login.swift")
        let fixed = try await svc.builds.build(BuildOptions(), in: &ctx)
        #expect(fixed.changedFileWarnings == [] && fixed.warningCount == 1, "\(fixed.text)")
        #expect(fixed.text.contains("\n1 warning in other files (xcd build --warnings)\n"), "\(fixed.text)")

        // The test run shares the package scheme's record with the builds above, so it sees the same warnings.
        let tests = try await svc.tests.test(TestOptions(showWarnings: true), in: &ctx)
        #expect(tests.outcome == .passed && messages(tests.warnings).contains { $0.hasPrefix("Other.swift:2") }, "\(tests.text)")
    }
}
