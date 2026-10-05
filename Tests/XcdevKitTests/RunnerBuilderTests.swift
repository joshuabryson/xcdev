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
    func stubBuild(timeoutsEnabled: Bool = false, exitCode: Int32 = 0, counter: Counter = Counter(),
                   beforeBuilding: (@Sendable () -> Void)? = nil) {
        fake.stub(["xcrun", "xcodebuild", "build-for-testing"]) { invocation in
            counter.increment()
            beforeBuilding?()
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

    @Test(arguments: [Int32(130), Int32(143)])
    func anInterruptedBuildIsNotRememberedAsFailed(exitCode: Int32) async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let builds = Counter()
        stubBuild(exitCode: exitCode, counter: builds)
        let first = await #expect(throws: XcdError.self) { _ = try await builder.ensureBuilt(xcode: xcode) }
        #expect(first?.code == .runnerFailed && first?.message.contains("interrupted or failed to run (exit \(exitCode))") == true)
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

    @Test func discardingABuildThatDoesNotExistDoesNothing() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        try await builder.discard(xcode: xcode)
        #expect(!FileManager.default.fileExists(atPath: home + "/cache/ui-runner/" + builder.key(for: xcode)))
    }

    @Test func aBuildThatProducesNoXctestrunIsRememberedAsFailed() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let builds = Counter()
        fake.stub(["xcrun", "xcodebuild", "build-for-testing"]) { _ in
            builds.increment()
            return ProcessOutput()
        }
        let first = await #expect(throws: XcdError.self) { _ = try await builder.ensureBuilt(xcode: xcode) }
        #expect(first?.code == .runnerFailed && first?.message == "the UI runner built but produced no .xctestrun")
        #expect(first?.next == "read the build log, then run `xcd ui stop --rebuild` to try again")
        #expect(FileManager.default.fileExists(atPath: home + "/cache/ui-runner/" + builder.key(for: xcode) + "/failed"))
        await #expect(throws: XcdError.self) { _ = try await builder.ensureBuilt(xcode: xcode) }
        #expect(builds.value == 1)                                   // not retried
    }

    @Test func discardWaitsForABuildInProgress() async throws {
        let gate = home + "-gate"
        try FileManager.default.createDirectory(atPath: gate, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: home)
            try? FileManager.default.removeItem(atPath: gate)
        }
        let directory = home + "/cache/ui-runner/" + builder.key(for: xcode)
        stubBuild(beforeBuilding: {
            FileManager.default.createFile(atPath: gate + "/started", contents: nil)
            for _ in 0..<3000 where !FileManager.default.fileExists(atPath: gate + "/release") { usleep(10_000) }
        })
        let discarded = Counter()
        let builder = self.builder
        let xcode = self.xcode
        let building = Task { try await builder.ensureBuilt(xcode: xcode) }
        for _ in 0..<3000 where !FileManager.default.fileExists(atPath: gate + "/started") { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: gate + "/started"))
        let discarding = Task { try await builder.discard(xcode: xcode); discarded.increment() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(discarded.value == 0)                                // blocked behind the build lock
        #expect(FileManager.default.fileExists(atPath: directory + "/project"))
        FileManager.default.createFile(atPath: gate + "/release", contents: nil)
        let build = try await building.value                          // returns only after the marker is written
        try await discarding.value
        #expect(build.directory == directory)
        #expect(discarded.value == 1)
        #expect(!FileManager.default.fileExists(atPath: directory))
    }

    @Test func anotherXcodeGetsItsOwnBuild() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        stubBuild()
        let a = try await builder.ensureBuilt(xcode: xcode)
        let b = try await builder.ensureBuilt(xcode: XcodeInstall(path: "/Applications/Xcode-beta.app", version: "27.1", build: "27B5011e"))
        #expect(a.key != b.key && a.directory != b.directory)
    }
}
