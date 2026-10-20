import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct XcodeOpenerTests {
    let worktree = FakeWorktree(prefix: "xcd-xcode")
    var fake: FakeProcessRunner { worktree.runner }
    var opener: XcodeOpener { XcodeOpener(runner: fake, provisioner: worktree.provisioner) }

    /// A context whose `project:` is `project`, created on disk unless `create` is false. `open` succeeds quietly.
    func context(project: String, create: Bool = true) throws -> WorktreeContext {
        fake.stub(["open"])
        return try worktree.context("version: 1\nproject: \(project)\n", container: create ? project : nil)
    }

    @Test func opensTheWorkspaceWithTheWorktreesXcode() async throws {
        defer { worktree.remove() }
        var ctx = try context(project: "App.xcworkspace")
        let report = try await opener.open(in: &ctx)
        #expect(fake.calls.map(\.executable) == ["/usr/bin/open"])
        #expect(fake.calls.last?.arguments == ["-a", "/Applications/Xcode.app", worktree.root + "/App.xcworkspace"])
        #expect(report.text == "opened App.xcworkspace in Xcode 27.0 (27A266a) /Applications/Xcode.app")
        #expect(report.envelopeWorktree == "feat")
    }

    /// `open` hands its own environment to the app it launches (seen on macOS 27 with a probe app), so a
    /// DEVELOPER_DIR in the caller's shell that names another Xcode would reach this one's script phases.
    @Test func theLaunchedXcodeGetsItsOwnDeveloperDir() async throws {
        defer { worktree.remove() }
        var ctx = try context(project: "App.xcworkspace")
        _ = try await opener.open(in: &ctx)
        #expect(fake.calls.last?.environment == ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"])
    }

    @Test func aFailedOpenSaysTheExactCommandToRunByHand() async throws {
        defer { worktree.remove() }
        var ctx = try context(project: "App.xcworkspace")
        fake.stub(["open"], exitCode: 1, stderr: "LSOpenURLsWithRole() failed with error -10814")
        do {
            _ = try await opener.open(in: &ctx)
            Issue.record("a failed open was reported as opened")
        } catch let error as XcdError {
            #expect(error.code == .subprocessFailed)
            #expect(error.next == "run open -a /Applications/Xcode.app '\(worktree.root)/App.xcworkspace' yourself")
        }
    }

    @Test func opensAPackageByItsManifest() async throws {
        defer { worktree.remove() }
        var ctx = try context(project: "Package.swift")
        let report = try await opener.open(in: &ctx)
        #expect(fake.calls.last?.arguments == ["-a", "/Applications/Xcode.app", worktree.root + "/Package.swift"])
        #expect(report.project == "Package.swift")
    }

    @Test func anXcodeGivenForThisRunWinsAndIsNotPinned() async throws {
        defer { worktree.remove() }
        var ctx = try context(project: "App.xcodeproj")
        ctx.xcodeOverride = XcodeInstall(path: "/Applications/Xcode-26.2.app", version: "26.2", build: "26C5")
        let report = try await opener.open(in: &ctx)
        #expect(fake.calls.last?.arguments == ["-a", "/Applications/Xcode-26.2.app", worktree.root + "/App.xcodeproj"])
        #expect(fake.calls.last?.environment == ["DEVELOPER_DIR": "/Applications/Xcode-26.2.app/Contents/Developer"])
        #expect(report.xcode.version == "26.2")
        #expect(ctx.state.xcode?.version == "27.0")
    }

    /// The project file is checked before the Xcode is resolved: on a worktree with no pin yet, the other order
    /// would run Xcode discovery (unstubbed here) before failing.
    @Test func aMissingProjectFileIsAConfigErrorAndOpensNothing() async throws {
        defer { worktree.remove() }
        var ctx = try context(project: "App.xcworkspace", create: false)
        ctx.state.xcode = nil
        do {
            _ = try await opener.open(in: &ctx)
            Issue.record("a missing project file was opened")
        } catch let error as XcdError {
            #expect(error.code == .configInvalid)
        }
        #expect(fake.calls.isEmpty)
    }
}
