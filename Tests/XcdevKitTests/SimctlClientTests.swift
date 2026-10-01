import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct SimctlClientTests {
    let fake = FakeProcessRunner()
    let noSleep: @Sendable (Duration) async throws -> Void = { _ in }

    @Test func passesDeveloperDirAndDecodesCatalog() async throws {
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        let client = SimctlClient(runner: fake, developerDir: "/X.app/Contents/Developer", sleep: noSleep)
        let catalog = try await client.catalog()
        #expect(catalog.devices.count == 1)
        #expect(fake.calls.last?.environment["DEVELOPER_DIR"] == "/X.app/Contents/Developer")
    }

    @Test func createCloneBootShutdownDelete() async throws {
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        let client = SimctlClient(runner: fake, developerDir: nil, sleep: noSleep)
        let catalog = try await client.catalog()
        let type = catalog.deviceTypes[0], runtime = catalog.runtimes[2]

        let template = try await client.create(name: "T", type: type, runtime: runtime)
        let clone = try await client.clone(udid: template, name: "C")
        #expect(sims.device(named: "C")?.runtimeIdentifier == runtime.identifier)

        #expect(try await client.boot(udid: clone) == 0)
        #expect(try await client.boot(udid: clone) == 0)            // already booted is fine
        #expect(fake.commandLines.contains("xcrun simctl bootstatus \(clone) -b"))
        #expect(try await client.shutdown(udid: clone) == 0)
        #expect(try await client.shutdown(udid: clone) == 0)        // already shut down is fine
        try await client.delete(udid: clone)
        try await client.delete(udid: clone)                        // already gone is fine
        #expect(sims.device(named: "C") == nil)
    }

    @Test func bootRetriesTransientStatesAndReportsCount() async throws {
        let attempts = Counter()
        fake.stub(["xcrun", "simctl", "boot"]) { _ in
            attempts.increment() <= 2
                ? ProcessOutput(exitCode: 149, stderr: "Unable to boot device in current state: Booting")
                : ProcessOutput()
        }
        fake.stub(["xcrun", "simctl", "bootstatus"])
        let client = SimctlClient(runner: fake, developerDir: nil, sleep: noSleep)
        #expect(try await client.boot(udid: "U") == 2)
    }

    @Test func bootGivesUpAfterThreeRetries() async throws {
        fake.stub(["xcrun", "simctl", "boot"], exitCode: 149, stderr: "Unable to boot device in current state: Shutting Down")
        let client = SimctlClient(runner: fake, developerDir: nil, sleep: noSleep)
        let error = await #expect(throws: XcdError.self) { try await client.boot(udid: "U") }
        #expect(error?.code == .simulatorFailed)
        #expect(error?.next == "run `xcd doctor`")
        #expect(fake.calls.count == 4)
    }

    @Test func cloneFailureIsCloneFailed() async throws {
        fake.stub(["xcrun", "simctl", "clone"], exitCode: 1, stderr: "Failed to clone")
        let client = SimctlClient(runner: fake, developerDir: nil, sleep: noSleep)
        let error = await #expect(throws: XcdError.self) { try await client.clone(udid: "U", name: "N") }
        #expect(error?.code == .cloneFailed)
    }
}
