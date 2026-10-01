import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct TemplateStoreTests {
    let locks = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-locks-\(UUID().uuidString)").path

    @Test func names() {
        let type = SimDeviceType(name: "iPhone 18 Pro", identifier: "t", productFamily: "iPhone")
        let runtime = SimRuntime(name: "iOS 27.0", identifier: "r", version: "27.0", platform: "iOS",
                                 isAvailable: true, supportedDeviceTypes: nil)
        #expect(SimNaming.template(ResolvedDevice(deviceType: type, runtime: runtime)) == "xcd-template · iPhone 18 Pro · iOS 27.0")
        #expect(SimNaming.clone(project: "SampleApp", worktree: "login", device: "iphone") == "xcd · SampleApp · login · iphone")
    }

    @Test func createsOnceThenReuses() async throws {
        let fake = FakeProcessRunner()
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        let simctl = SimctlClient(runner: fake, developerDir: nil)
        let resolved = try DeviceResolver.resolve(name: "iphone", spec: DeviceSpec(type: "iPhone 18 Pro"),
                                                  catalog: try await simctl.catalog())
        let store = TemplateStore(simctl: simctl, locksDirectory: locks)
        let first = try await store.ensureTemplate(for: resolved)
        let second = try await store.ensureTemplate(for: resolved)
        #expect(first == second)
        #expect(sims.createCount == 1)
        #expect(sims.device(named: "xcd-template · iPhone 18 Pro · iOS 27.0")?.udid == first)
    }

    @Test func concurrentEnsureCreatesOneTemplate() async throws {
        let fake = FakeProcessRunner()
        let sims = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        let simctl = SimctlClient(runner: fake, developerDir: nil)
        let resolved = try DeviceResolver.resolve(name: "iphone", spec: DeviceSpec(type: "iPhone 18 Pro"),
                                                  catalog: try await simctl.catalog())
        let udids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { try await TemplateStore(simctl: simctl, locksDirectory: locks).ensureTemplate(for: resolved) }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(udids.count == 1)
        #expect(sims.createCount == 1)
    }

    @Test func fileLockSerializesCriticalSections() async throws {
        let path = locks + "/test.lock"
        let inside = Counter()
        let maxInside = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await FileLock.withLock(at: path) {
                        let now = inside.increment()
                        if now > 1 { maxInside.increment() }
                        try await Task.sleep(for: .milliseconds(20))
                        _ = inside.decrement()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(maxInside.value == 0)
    }
}
