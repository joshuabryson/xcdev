import Foundation
import Testing
@testable import XcdevKit

@Suite struct WorktreeStateTests {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-state-\(UUID().uuidString)").path

    func sampleState(name: String = "feat", root: String = "/p") -> WorktreeState {
        WorktreeState(id: UUID().uuidString, name: name, project: "App", projectRoot: root, path: base + "/" + name,
                      branch: name, xcode: XcodeInstall(path: "/Applications/Xcode.app", version: "27.0", build: "27A266a"),
                      devices: ["iphone": ProvisionedDevice(udid: "U", deviceType: "iPhone 18 Pro",
                                                            deviceTypeIdentifier: "t", runtime: "iOS 27.0",
                                                            runtimeIdentifier: "r")],
                      status: .ready, createdAt: Date(timeIntervalSince1970: 1_790_040_000))
    }

    @Test func globalPathsHonorXcdevHome() {
        #expect(GlobalPaths.live(environment: ["XCDEV_HOME": "/tmp/h"]).registryFile == "/tmp/h/registry.json")
        #expect(GlobalPaths.live(environment: [:]).base.hasSuffix("/Library/Application Support/xcdev"))
    }

    @Test func worktreePathsLayout() {
        let p = WorktreePaths(root: "/w")
        #expect(p.stateFile == "/w/.xcdev/worktree.json")
        #expect(p.derivedData == "/w/.xcdev/DerivedData")
        #expect(p.sourcePackages == "/w/.xcdev/SourcePackages")
    }

    @Test func stateRoundTripsAndSelfIgnores() throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let state = sampleState()
        let paths = WorktreePaths(root: state.path)
        #expect(try WorktreeStateStore.load(paths) == nil)
        try WorktreeStateStore.save(state, paths)
        #expect(try WorktreeStateStore.load(paths) == state)
        #expect(try String(contentsOfFile: paths.stateDirectory + "/.gitignore", encoding: .utf8) == "*\n")
    }

    @Test func registryUpsertReplacesByIdOrProjectAndName() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let registry = Registry(paths: GlobalPaths(base: base))
        #expect(try registry.entries().isEmpty)
        var state = sampleState()
        try await registry.upsert(RegistryEntry(state))
        state.status = .incomplete
        try await registry.upsert(RegistryEntry(state))
        #expect(try registry.entries().map(\.status) == [.incomplete])

        var replacement = sampleState()                 // same project+name, new id
        replacement.id = "other"
        try await registry.upsert(RegistryEntry(replacement))
        #expect(try registry.entries().map(\.id) == ["other"])

        try await registry.remove(id: "other")
        #expect(try registry.entries().isEmpty)
    }

    @Test func concurrentUpsertsAreAllKept() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        let registry = Registry(paths: GlobalPaths(base: base))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                let state = sampleState(name: "wt\(i)")
                group.addTask { try await registry.upsert(RegistryEntry(state)) }
            }
            try await group.waitForAll()
        }
        #expect(try registry.entries().count == 20)
    }
}
