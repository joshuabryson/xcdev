import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct SimulatorSDKsTests {
    func runtime(_ platform: String, _ version: String) -> SimRuntime {
        SimRuntime(name: "\(platform) \(version)", identifier: "rt-\(platform)-\(version)", version: version,
                   platform: platform, isAvailable: true, supportedDeviceTypes: nil)
    }

    @Test func parsesRecordedShowSDKs() throws {
        let sdks = try SimulatorSDKs.parse(Data(Fixture.string("showsdks.json").utf8))
        #expect(sdks.versions == ["iOS": "27.0", "watchOS": "27.0", "tvOS": "27.0", "xrOS": "27.0"])
    }

    @Test func comparesMajorMinorOnly() {
        let sdks = SimulatorSDKs(versions: ["iOS": "27.0"])
        #expect(sdks.supports(runtime("iOS", "27.0")))
        #expect(sdks.supports(runtime("iOS", "27.0.1")))
        #expect(sdks.supports(runtime("iOS", "26.5")))
        #expect(!sdks.supports(runtime("iOS", "27.1")))
        #expect(sdks.supports(runtime("watchOS", "99.0")))      // no SDK for the platform: let xcodebuild decide
    }

    @Test func badJSONIsReported() {
        let error = #expect(throws: XcdError.self) { try SimulatorSDKs.parse(Data("nope".utf8)) }
        #expect(error?.code == .subprocessFailed)
    }

    @Test func storeCachesPerXcode() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-sdks-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fake = FakeProcessRunner()
        fake.stub(["xcrun", "xcodebuild", "-showsdks", "-json"], stdout: FakeSimulators.sdksJSON)
        let store = SDKStore(runner: fake, cacheDirectory: dir)
        let xcode = XcodeInstall(path: "/Applications/Xcode.app", version: "27.0", build: "27A266a")
        #expect(try await store.sdks(for: xcode).versions["iOS"] == "27.0")
        #expect(try await store.sdks(for: xcode).versions["iOS"] == "27.0")
        #expect(fake.calls.count == 1)
        #expect(fake.calls[0].environment["DEVELOPER_DIR"] == "/Applications/Xcode.app/Contents/Developer")
    }
}
