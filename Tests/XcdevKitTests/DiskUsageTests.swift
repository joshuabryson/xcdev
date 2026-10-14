import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct DiskUsageTests {
    @Test func parsesRecordedDuOutput() {
        // `du -sk` with three paths, one missing: the missing one only appears on stderr (and du exits 1).
        let recorded = "296\t/Users/dev/My Apps/du one/.xcdev\n0\t/Users/dev/My Apps/du two/.xcdev\n"
        let expected: [String: Int64] = ["/Users/dev/My Apps/du one/.xcdev": 296 * 1024, "/Users/dev/My Apps/du two/.xcdev": 0]
        #expect(DiskUsage.parse(recorded) == expected)
    }

    @Test func measuresExistingPathsAndSkipsMissingOnes() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("xcd du \(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base + "/with space", withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: URL(fileURLWithPath: base + "/with space/blob"))
        let sizes = await DiskUsage(runner: SystemProcessRunner()).bytes(of: [base + "/with space", base + "/missing"])
        #expect(sizes.keys.sorted() == [base + "/with space"])
        #expect((sizes[base + "/with space"] ?? 0) >= 300_000)
    }

    @Test func byteText() {
        #expect(ByteText.format(0) == "0B")
        #expect(ByteText.format(512) == "512B")
        #expect(ByteText.format(296 * 1024) == "296KB")
        #expect(ByteText.format(12_900_000) == "12.3MB")
        #expect(ByteText.format(1_288_490_189) == "1.2GB")
    }

    @Test func simctlReportsEachDevicesFolderAndSize() throws {
        let catalog = try SimCatalog.decode(Data(Fixture.string("simctl-list-init.json").utf8))
        let template = try #require(catalog.devices.first { $0.name == "xcd-template · iPhone 18 Pro · iOS 27.0" })
        #expect(template.dataPathSize == 18_337_792)
        #expect(template.deviceDirectory == "/Users/dev/Library/Developer/CoreSimulator/Devices/74A4C63D-F615-4A06-A501-9D93463D7756")
    }

    @Test func worktreeListShowsEachWorktreesStateFolderSize() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        let svc = WorktreeService(runner: RoutingRunner(fake: FakeProcessRunner(), realExecutables: ["git", "cp", "du"]),
                                  globalPaths: GlobalPaths(base: project.home))
        let main = try await svc.open(from: project.root)
        try Data(count: 200_000).write(to: URL(fileURLWithPath: main.paths.logs + "-blob"))
        let items = try await svc.listDetails(projectRoot: project.root)
        #expect((items.first?.diskBytes ?? 0) >= 200_000)
        #expect(WorktreeListReport(worktrees: items, includeProject: false).text.contains("  devices=none  disk="))
    }
}
