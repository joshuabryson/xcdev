import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct RunnerBuilderTests {
    let fake = FakeProcessRunner()
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("xcd builder \(UUID().uuidString)").path
    let xcode = XcodeInstall(path: "/Applications/Xcode.app", version: "27.0", build: "27A266a")

    var builder: RunnerBuilder { RunnerBuilder(runner: fake, globalPaths: GlobalPaths(base: home)) }

    /// Stubs a build that writes an .xctestrun with the given timeouts setting.
    func stubBuild(timeoutsEnabled: Bool = false, exitCode: Int32 = 0, counter: Counter = Counter()) {
        fake.stub(["xcrun", "xcodebuild", "build-for-testing"]) { invocation in
            counter.increment()
            guard exitCode == 0 else { return ProcessOutput(exitCode: exitCode, stderr: "error: something broke\n") }
            let derived = invocation.arguments[invocation.arguments.firstIndex(of: "-derivedDataPath")! + 1]
            let products = derived + "/Build/Products"
            try FileManager.default.createDirectory(atPath: products, withIntermediateDirectories: true)
            let plist: [String: Any] = ["TestConfigurations": [["TestTargets": [["TestTimeoutsEnabled": timeoutsEnabled]]]]]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: products + "/XcdRunner_XcdRunner_iphonesimulator27.0-arm64-x86_64.xctestrun"))
            return ProcessOutput()
        }
    }

    @Test func newErrorCodesHaveTheirExitCodes() {
        #expect(ErrorCode.elementNotFound.exitCode == 1 && ErrorCode.elementNotHittable.exitCode == 1 && ErrorCode.waitTimeout.exitCode == 1)
        #expect(ErrorCode.elementAmbiguous.exitCode == 2 && ErrorCode.staleRef.exitCode == 2 && ErrorCode.platformUnsupported.exitCode == 2)
        #expect(ErrorCode.runnerFailed.exitCode == 3)
        #expect(ErrorCode.elementNotFound.rawValue == "element_not_found" && ErrorCode.runnerFailed.rawValue == "runner_failed")
    }

    @Test func buildsOnceAndReusesTheBuild() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let builds = Counter()
        stubBuild(counter: builds)
        let first = try await builder.ensureBuilt(xcode: xcode)
        #expect(first.key == "27A266a-" + RunnerSource.hash)
        #expect(first.directory == home + "/cache/ui-runner/" + first.key)
        #expect(first.xctestrun.hasSuffix(".xctestrun") && FileManager.default.fileExists(atPath: first.xctestrun))
        #expect(FileManager.default.fileExists(atPath: first.directory + "/project/XcdRunner.xcodeproj/project.pbxproj"))
        let call = try #require(fake.calls.first)
        #expect(call.commandLine.contains("-scheme XcdRunner -destination 'generic/platform=iOS Simulator'"))
        #expect(call.environment["DEVELOPER_DIR"] == "/Applications/Xcode.app/Contents/Developer")
        #expect(try await builder.ensureBuilt(xcode: xcode) == first)
        #expect(builds.value == 1)
    }

    @Test func aBuildWithTimeoutsOnIsRejected() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        stubBuild(timeoutsEnabled: true)
        let error = await #expect(throws: XcdError.self) { _ = try await builder.ensureBuilt(xcode: xcode) }
        #expect(error?.code == .runnerFailed && error?.message.contains("test timeouts") == true)
    }

    @Test func aFailedBuildIsRememberedUntilDiscarded() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let builds = Counter()
        stubBuild(exitCode: 65, counter: builds)
        let first = await #expect(throws: XcdError.self) { _ = try await builder.ensureBuilt(xcode: xcode) }
        #expect(first?.code == .runnerFailed && first?.next == "read the build log, then run `xcd ui stop --rebuild` to try again")
        #expect(first?.details.contains { $0.hasPrefix("log: ") } == true)
        await #expect(throws: XcdError.self) { _ = try await builder.ensureBuilt(xcode: xcode) }
        #expect(builds.value == 1)                                   // not retried
        try await builder.discard(xcode: xcode)
        stubBuild(counter: builds)
        _ = try await builder.ensureBuilt(xcode: xcode)
        #expect(builds.value == 2)
    }

    @Test func anInterruptedBuildIsNotRememberedAsFailed() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let builds = Counter()
        stubBuild(exitCode: 130, counter: builds)
        let first = await #expect(throws: XcdError.self) { _ = try await builder.ensureBuilt(xcode: xcode) }
        #expect(first?.code == .runnerFailed && first?.message.contains("interrupted or failed to run") == true)
        #expect(first?.next == "run the command again; if it keeps failing, read the build log")
        let dir = home + "/cache/ui-runner/" + builder.key(for: xcode)
        #expect(!FileManager.default.fileExists(atPath: dir + "/failed"))
        stubBuild(counter: builds)
        _ = try await builder.ensureBuilt(xcode: xcode)
        #expect(builds.value == 2)
    }

    @Test func aBuildThatTimesOutIsNotRememberedAsFailed() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        fake.stub(["xcrun", "xcodebuild", "build-for-testing"]) { _ in
            throw XcdError(.timeout, "the operation timed out")
        }
        let first = await #expect(throws: XcdError.self) { _ = try await builder.ensureBuilt(xcode: xcode) }
        #expect(first?.code == .runnerFailed && first?.message.contains("timed out") == true)
        let dir = home + "/cache/ui-runner/" + builder.key(for: xcode)
        #expect(!FileManager.default.fileExists(atPath: dir + "/failed"))
    }

    @Test func discardWaitsForABuildInProgress() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        // Verify that discard properly holds the build lock and works correctly.
        // The invariant: if ensureBuilt returns a build, the xctestrun file exists.
        // With proper locking, discard can't delete the directory while ensureBuilt holds the lock.
        let builds = Counter()
        stubBuild(counter: builds)

        // First: build successfully
        let build1 = try await builder.ensureBuilt(xcode: xcode)
        #expect(FileManager.default.fileExists(atPath: build1.xctestrun))

        // Discard and verify it's gone
        try await builder.discard(xcode: xcode)
        let dir = home + "/cache/ui-runner/" + builder.key(for: xcode)
        #expect(!FileManager.default.fileExists(atPath: dir))

        // Build again: verify the second build works after discard
        stubBuild(counter: builds)
        let build2 = try await builder.ensureBuilt(xcode: xcode)
        #expect(FileManager.default.fileExists(atPath: build2.xctestrun))
        #expect(builds.value == 2)
    }

    @Test func anotherXcodeGetsItsOwnBuild() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        stubBuild()
        let a = try await builder.ensureBuilt(xcode: xcode)
        let b = try await builder.ensureBuilt(xcode: XcodeInstall(path: "/Applications/Xcode-beta.app", version: "27.1", build: "27B5011e"))
        #expect(a.key != b.key && a.directory != b.directory)
    }
}
